import ArgumentParser
import Foundation
import Virtualization

/// Default VM name. Overridden by --vm-name when the wrapper passes
/// a content-addressed name (e.g. darvm-a1b2c3d4).
let defaultVMName = "darvm-base"

/// Set by signal handler to interrupt blocking operations (e.g. mount retry loop).
/// Accessed from multiple threads — nonisolated(unsafe) since we only do atomic flag reads/writes.
nonisolated(unsafe) var stopRequested = false

/// Elapsed time since process start, for timestamped log output.
private let processStartTime = CFAbsoluteTimeGetCurrent()
func tprint(_ message: String) {
    let elapsed = CFAbsoluteTimeGetCurrent() - processStartTime
    let secs = Int(elapsed)
    let ms = Int((elapsed - Double(secs)) * 1000)
    print(String(format: "[%3d.%03ds] %@", secs, ms, message))
}

// MARK: - Structured logging

/// Structured JSON logger for DVM. Writes JSON lines to /tmp/dvm-<pid>.log.
/// In debug mode, also emits to stderr.
struct DVMLog {
    /// Unique run identifier, shared with VMStatus.
    static let runId: String = {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }()

    /// When true, JSON log lines are also written to stderr.
    nonisolated(unsafe) static var debugMode = false

    static let logPath = "/tmp/dvm-\(ProcessInfo.processInfo.processIdentifier).log"

    private static let logHandle: FileHandle? = {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        return FileHandle(forWritingAtPath: logPath)
    }()

    static func log(phase: VMPhase? = nil, level: String = "info", _ msg: String) {
        let elapsed = CFAbsoluteTimeGetCurrent() - processStartTime
        var entry: [String: Any] = [
            "t": String(format: "%.3f", elapsed),
            "level": level,
            "msg": msg,
            "run_id": runId,
        ]
        if let phase { entry["phase"] = phase.rawValue }

        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let lineWithNewline = line + "\n"

        logHandle?.write(lineWithNewline.data(using: .utf8)!)

        if debugMode {
            fputs(lineWithNewline, stderr)
        }
    }
}

@main
struct DVM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dvm-core",
        abstract: "DVM core — VM lifecycle management",
        subcommands: [Start.self, Stop.self, Exec.self, SSH.self, Status.self, ConfigGet.self, ReloadCapabilities.self]
    )

    static func main() async {
        // Line-buffer stdout so output appears promptly when backgrounded/redirected
        setlinebuf(stdout)
        await self.main(nil)
    }
}

// MARK: - Helpers

func vmDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tart/vms/\(defaultVMName)")
}

/// Resolve guest IP via control socket (preferred) or DHCP lease fallback.
func resolveGuestIP() throws -> GuestIP {
    // Prefer control socket — avoids stale DHCP lease issues
    if case .success(.status(let payload)) = ControlSocket.send(.status),
       payload.running,
       let ipStr = payload.ip,
       let ip = GuestIP(ipStr) {
        return ip
    }

    // Fallback to DHCP lease (control socket may not be running, e.g. Tart-managed VM)
    let configURL = vmDir().appendingPathComponent("config.json")
    let config = try TartConfig(fromURL: configURL)
    guard let ip = DHCPLeaseParser.getIPAddress(forMAC: config.macAddress.string) else {
        throw DVMError.noIPAddress
    }
    return ip
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Guest user home. The base image has user "admin" with UID 501.
let guestHome = "/Users/admin"

/// Build mount configs from mirror, home, and system directory lists.
///
/// - mirror dirs: mounted at the same absolute path in the guest (project dirs, read-write)
/// - home dirs: mounted relative to the guest user's home (config/data dirs, read-write)
/// - system dirs: mounted at the same absolute path in the guest (toolchains, read-only)
///
/// WARNING: Do NOT mount ~/.config/dvm — it contains user configuration.
/// A writable mount would let a rogue guest modify host settings.
func buildMounts(hostHome: String, mirrorDirs: [String], homeDirs: [String], systemDirs: [String] = []) throws -> [MountConfig] {
    var mounts: [MountConfig] = [
        .exact(tag: try MountTag("nix-store"),
               hostPath: try AbsolutePath("/nix/store"),
               guestPath: try AbsolutePath("/nix/store"),
               access: .readOnly),
        .exact(tag: try MountTag("nix-cache"),
               hostPath: try AbsolutePath("\(hostHome)/.cache/nix"),
               guestPath: try AbsolutePath("\(guestHome)/.cache/nix"),
               access: .readWrite),
    ]

    for (i, d) in mirrorDirs.enumerated() {
        let resolved = URL(
            fileURLWithPath: (d as NSString).expandingTildeInPath
        ).standardizedFileURL.path
        mounts.append(.exact(
            tag: try MountTag("mirror-\(i)"),
            hostPath: try AbsolutePath(resolved),
            guestPath: try AbsolutePath(resolved),
            access: .readWrite
        ))
    }

    for (i, d) in homeDirs.enumerated() {
        // Resolve host path (expand ~)
        let hostPath = URL(
            fileURLWithPath: (d as NSString).expandingTildeInPath
        ).standardizedFileURL.path

        // Guest path: replace host home prefix with guest home
        let guestPath: String
        if hostPath.hasPrefix(hostHome) {
            guestPath = guestHome + hostPath.dropFirst(hostHome.count)
        } else {
            // Not under host home — mount at same path
            guestPath = hostPath
        }

        mounts.append(.exact(
            tag: try MountTag("home-\(i)"),
            hostPath: try AbsolutePath(hostPath),
            guestPath: try AbsolutePath(guestPath),
            access: .readWrite
        ))
    }

    // System dirs: same absolute path in guest, read-only.
    // Used for host toolchains (Xcode, developer tools) that should be
    // shared immutably — enforced at the VirtioFS device level (EROFS).
    for (i, d) in systemDirs.enumerated() {
        let resolved = URL(fileURLWithPath: d).standardizedFileURL.path
        mounts.append(.exact(
            tag: try MountTag("system-\(i)"),
            hostPath: try AbsolutePath(resolved),
            guestPath: try AbsolutePath(resolved),
            access: .readOnly
        ))
    }

    return mounts
}

/// A validated Nix store path (starts with `/nix/store/`).
struct NixStorePath {
    let rawValue: String

    init(_ output: String) throws {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/nix/store/"), !trimmed.contains("\n") else {
            throw DVMError.invalidStorePath(trimmed)
        }
        self.rawValue = trimmed
    }
}

enum DVMError: Error, CustomStringConvertible {
    case noIPAddress
    case buildFailed
    case invalidStorePath(String)
    case activationFailed(String)
    case alreadyRunning

    var description: String {
        switch self {
        case .noIPAddress: return "Could not resolve VM IP address. Is the VM running?"
        case .buildFailed: return "nix build failed"
        case .invalidStorePath(let s): return "Invalid nix store path from build output: \(s)"
        case .activationFailed(let msg): return "Activation failed: \(msg)"
        case .alreadyRunning: return "A VM is already running. Stop it first or use `dvm switch` to apply changes."
        }
    }
}

/// Format seconds as "Xm Ys" or "Xs".
private func formatElapsed(_ seconds: Double) -> String {
    let secs = Int(seconds)
    if secs >= 60 {
        return "\(secs / 60)m \(secs % 60)s"
    }
    return "\(secs)s"
}

// MARK: - Start

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot the VM and block until stopped (Ctrl-C)"
    )

    @Option(name: .long, parsing: .upToNextOption,
            help: "Mirror-mount directories (same absolute path in guest)")
    var dir: [String] = []

    @Option(name: .long, parsing: .upToNextOption,
            help: "Home-mount directories (relative to guest user's home)")
    var homeDir: [String] = []

    @Option(name: .long, parsing: .upToNextOption,
            help: "System directories to mount read-only (same path in guest)")
    var systemDir: [String] = []

    @Option(name: .long, help: "Nix store path to the desired nix-darwin system closure")
    var systemClosure: String?

    @Flag(name: .long, help: "Verbose output: structured logs + guest log streaming")
    var debug: Bool = false

    @Option(name: .long, help: "Custom macOS log predicate for guest log streaming (implies --debug)")
    var logPredicate: String?

    @Option(name: .long, help: "Tart VM name")
    var vmName: String?

    @Option(name: .long, help: "Path to capabilities.json manifest (must be in /nix/store/)")
    var capabilities: String?

    @MainActor
    func run() async throws {
        let effectiveDebug = debug || logPredicate != nil || ProcessInfo.processInfo.environment["DVM_DEBUG"] == "1"
        DVMLog.debugMode = effectiveDebug
        DVMLog.log(phase: .stopped, "dvm starting (run_id=\(DVMLog.runId), log=\(DVMLog.logPath))")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let config = try DVMConfig.load()
        let mounts = try buildMounts(
            hostHome: home,
            mirrorDirs: config.mirrorDirs + dir,
            homeDirs: config.homeDirs + homeDir,
            systemDirs: systemDir
        )

        // Control socket for CLI coordination (status, stop, etc.)
        // Check for an already-running instance BEFORE creating our socket.
        // ControlSocket.listen() unlinks the existing socket file, which would
        // orphan the running instance (it becomes unreachable via the control
        // socket even though the VM is still running).
        if ControlSocket.isRunning() {
            throw DVMError.alreadyRunning
        }
        let controlSocket = ControlSocket()
        try controlSocket.listen()

        // Phase: configuring
        let effectiveVMName = vmName ?? defaultVMName
        let vmDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tart/vms/\(effectiveVMName)")
        controlSocket.update(.configuring)
        DVMLog.log(phase: .configuring, "configuring VM from \(vmDirectory.path)")
        tprint("Configuring VM from \(vmDirectory.path)...")

        // Credential proxy: always launch sidecar with empty secrets.
        // Credentials are pushed per-project at exec/ssh time, not at startup.
        var caCertPEM = ""

        let netstackBinary = ProcessInfo.processInfo.environment["DVM_NETSTACK"]
            ?? "/usr/local/bin/dvm-netstack"

        let netstackConfig = NetstackSupervisor.Config(
            netstackBinary: netstackBinary,
            subnet: "192.168.64.0/24",
            gatewayIP: "192.168.64.1",
            guestIP: "192.168.64.2",
            dnsServers: ["8.8.8.8", "8.8.4.4"],
            caCertPEM: "",
            caKeyPEM: ""
        )

        let netstackSupervisor = try NetstackSupervisor.launch(
            config: netstackConfig,
            onCrash: {
                DVMLog.log(level: "error", "dvm-netstack crashed — networking is down, failing closed")
                tprint("FATAL: Credential proxy (dvm-netstack) crashed. VM networking is down.")
            }
        )

        try netstackSupervisor.configure(config: netstackConfig)
        caCertPEM = netstackSupervisor.caCertPEM
        DVMLog.log(phase: .configuring, "dvm-netstack sidecar ready (CA: \(caCertPEM.isEmpty ? "none" : "\(caCertPEM.count) bytes"))")
        netstackSupervisor.startMonitoring()
        tprint("Credential proxy started.")

        // Create state directory for host↔guest activation state exchange.
        // Shared via VirtioFS as "dvm-state", mounted at /var/run/dvm-state in guest.
        let dvmLocalDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/dvm")
        let stateDir = URL(fileURLWithPath: dvmLocalDir.path)
        // Clean up stale state from previous runs
        try? FileManager.default.removeItem(at: stateDir)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        DVMLog.log(phase: .configuring, "state dir: \(stateDir.path)")

        // Host-backed guest home directory.
        // The guest VM disk has ~1GB free after macOS /System (~45GB on a 46GB
        // disk). User data (tool caches, configs, node_modules temp, etc.) must
        // live on the host to avoid NoSpaceLeft errors. This directory backs
        // /Users/admin in the guest via VirtioFS, mounted by the boot script
        // before any launchd services touch ~/. Created once, persists across
        // VM rebuilds — tool caches, shell history, etc. survive dvm init.
        let homeDataDir = dvmLocalDir
            .deletingLastPathComponent() // ~/.local/state
            .deletingLastPathComponent() // ~/.local
            .appendingPathComponent("state/dvm/home")
        if !FileManager.default.fileExists(atPath: homeDataDir.path) {
            try FileManager.default.createDirectory(at: homeDataDir, withIntermediateDirectories: true)
            DVMLog.log(phase: .configuring, "created home data dir: \(homeDataDir.path)")
        }
        DVMLog.log(phase: .configuring, "home data dir: \(homeDataDir.path)")

        // Write activation files if closure provided. The guest's mount script
        // touches the trigger after mounting, which fires the activator daemon.
        if let closure = systemClosure {
            try closure.write(
                to: stateDir.appendingPathComponent("closure-path"),
                atomically: true, encoding: .utf8)
            try DVMLog.runId.write(
                to: stateDir.appendingPathComponent("run-id"),
                atomically: true, encoding: .utf8)
            DVMLog.log(phase: .configuring, "activation requested: \(closure)")
        }

        let configured = try VMConfigurator.create(
            vmDir: vmDirectory,
            mounts: mounts,
            netstackFD: netstackSupervisor.vmFD,
            stateDir: stateDir,
            homeDataDir: homeDataDir
        )
        let effectiveMounts = configured.effectiveMounts

        let runner = VMRunner(configured)

        // Phase: booting
        controlSocket.update(.booting)
        DVMLog.log(phase: .booting, "starting VM")

        // Signal handler: Ctrl-C stops the VM immediately.
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let handleStop: @Sendable () -> Void = {
            stopRequested = true
            controlSocket.update(.stopping)
            DVMLog.log(phase: .stopping, "stop signal received")
            Task { @MainActor in
                tprint("Stopping VM...")
                try? await runner.stop()
            }
        }
        sigintSource.setEventHandler(handler: handleStop)
        sigtermSource.setEventHandler(handler: handleStop)
        sigintSource.resume()
        sigtermSource.resume()

        tprint("Starting VM...")
        try await runner.start()

        // Start host-side bridges
        let bridge = try VsockDaemonBridge(vm: runner.vm)
        bridge.start()

        let agentProxy = try AgentProxy(vm: runner.vm)
        agentProxy.start()

        // Host action bridge: forward capability actions from guest → host
        var hostCmdBridge: HostCommandBridge?
        if let capPath = capabilities {
            let manifest = try CapabilitiesManifest.load(from: capPath)
            if !manifest.handlers.isEmpty {
                hostCmdBridge = try HostCommandBridge(
                    vm: runner.vm,
                    manifest: manifest
                )
                hostCmdBridge!.start()
            }
        }

        // Register reload handler so `dvm switch` can hot-reload capabilities
        controlSocket.reloadCapabilitiesHandler = { [weak runner] path in
            // Must dispatch to main actor for VZ framework access
            final class Box: @unchecked Sendable { var result: String? }
            let box = Box()
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                do {
                    let newManifest = try CapabilitiesManifest.load(from: path)
                    if let bridge = hostCmdBridge {
                        try bridge.reload(from: path)
                    } else if !newManifest.handlers.isEmpty, let vm = runner?.vm {
                        let bridge = try HostCommandBridge(vm: vm, manifest: newManifest)
                        bridge.start()
                        hostCmdBridge = bridge
                    }
                    // If manifest is empty and no bridge exists, nothing to do
                } catch {
                    box.result = "\(error)"
                }
                semaphore.signal()
            }
            let waitResult = semaphore.wait(timeout: .now() + 5)
            if waitResult != .success { return "reload timed out" }
            return box.result
        }

        let agentClient = AgentClient()

        // Check for guest boot errors. The boot mount script (dvm-mount-store)
        // writes an error marker to dvm-state if an infrastructure mount fails,
        // then halts the VM. We check for this marker during activation and
        // agent wait phases to surface the failure quickly.
        let bootErrorFile = stateDir.appendingPathComponent("boot-error")
        func checkBootError() -> String? {
            guard let error = try? String(contentsOf: bootErrorFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !error.isEmpty else { return nil }
            return error
        }

        // Phase: activating (if closure was provided)
        // Watch state files on host filesystem — the state dir is shared via
        // VirtioFS, so guest writes are instantly visible to the host.
        // On first boot, the agent doesn't exist yet; activation installs it.
        if systemClosure != nil {
            controlSocket.update(.activating)
            DVMLog.log(phase: .activating, "waiting for guest activation via state files")
            tprint("Waiting for guest activation...")

            let runDir = stateDir.appendingPathComponent(DVMLog.runId)
            let statusFile = runDir.appendingPathComponent("status")
            let logFile = runDir.appendingPathComponent("activation.log")
            let deadline = Date().addingTimeInterval(300) // 5 min timeout

            var activationSucceeded = false
            while Date() < deadline && !stopRequested {
                // Check for boot-level failures (infrastructure mount failure → VM halt)
                if let bootError = checkBootError() {
                    DVMLog.log(phase: .activating, level: "error", "guest boot failed: \(bootError)")
                    tprint("FATAL: Guest boot failed: \(bootError)")
                    try? await runner.stop()
                    throw DVMError.activationFailed("guest boot failed: \(bootError)")
                }
                if let statusText = try? String(contentsOf: statusFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) {
                    if statusText == "done" {
                        activationSucceeded = true
                        DVMLog.log(phase: .activating, "activation succeeded")
                        tprint("Activation succeeded.")
                        break
                    }
                    if statusText == "failed" || statusText == "invalid-closure" {
                        let exitCode = (try? String(contentsOf: runDir.appendingPathComponent("exit-code"),
                                                    encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                        DVMLog.log(phase: .activating, level: "error",
                                   "activation failed (status=\(statusText), exit=\(exitCode))")
                        if let log = try? String(contentsOf: logFile, encoding: .utf8) {
                            let tail = String(log.suffix(2000))
                            tprint("Activation failed (exit code \(exitCode)). Log tail:")
                            tprint(tail)
                        } else {
                            tprint("Activation failed (exit code \(exitCode)). No log available.")
                        }
                        break
                    }
                    // "running" — still in progress
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }

            if !activationSucceeded && !stopRequested {
                if Date() >= deadline {
                    DVMLog.log(phase: .activating, level: "error", "activation timed out after 5 min")
                    tprint("Warning: activation did not complete within 5 minutes.")
                }
                // Continue anyway — agent might still come up
            }
        }

        // Phase: waitingForAgent
        // Simplified: just poll gRPC. On first boot the agent is installed by
        // activation; on subsequent boots it starts from /nix/store via KeepAlive.
        controlSocket.update(.waitingForAgent)
        DVMLog.log(phase: .waitingForAgent, "waiting for guest agent")
        tprint("Waiting for guest agent...")

        let agentConnected: Bool = await {
            let deadline = Date().addingTimeInterval(120) // 2 min
            while Date() < deadline && !stopRequested {
                // Check for boot-level failures before the agent is even available
                if let bootError = checkBootError() {
                    DVMLog.log(phase: .waitingForAgent, level: "error", "guest boot failed: \(bootError)")
                    tprint("FATAL: Guest boot failed: \(bootError)")
                    return false
                }
                if let _ = try? await agentClient.status() {
                    return true
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return false
        }()

        if agentConnected {
            DVMLog.log(phase: .waitingForAgent, "agent is reachable")
            tprint("Guest agent connected.")
        } else if !stopRequested {
            controlSocket.update(.failed, error: "guest agent unreachable")
            tprint("Stopping VM.")
            try? await runner.stop()
            controlSocket.cleanup()
            agentProxy.cleanup()
            throw DVMError.activationFailed("guest agent unreachable")
        }

        // Resolve guest IP via gRPC
        let ip: GuestIP
        do {
            ip = try await agentClient.resolveIP()
            tprint("VM reachable at \(ip)")
            DVMLog.log(phase: .waitingForAgent, "guest IP: \(ip)")
        } catch {
            // Fallback to DHCP
            if let dhcpIP = runner.resolveIP() {
                ip = dhcpIP
                tprint("VM reachable at \(ip) (DHCP fallback)")
            } else {
                let msg = "Could not resolve guest IP: \(error)"
                controlSocket.update(.failed, error: msg)
                DVMLog.log(phase: .failed, level: "error", msg)
                tprint("Warning: \(msg)")
                tprint("VM running. Press Ctrl-C to stop.")
                await runner.waitUntilStopped()
                controlSocket.cleanup()
                agentProxy.cleanup()
                tprint("VM stopped.")
                return
            }
        }

        // Phase: mounting
        // Infrastructure mounts (nix-store, dvm-home) are already mounted by
        // the image's boot script (dvm-mount-store). Mount remaining shares
        // (nix-cache, mirror dirs, home dirs) via gRPC exec.
        // Note: dvm-home (guest home at /Users/admin) is an early-boot mount
        // because it must land before any launchd service touches ~/. This is
        // critical for GUI login where WindowServer/Finder/Dock race on ~.
        let bootMountedTags: Set<String> = ["nix-store", "dvm-home"]
        let remainingMounts = effectiveMounts.filter { mount in
            guard case .exact(let tag, _, _, _) = mount else { return false }
            return !bootMountedTags.contains(tag.rawValue)
        }
        controlSocket.update(.mounting, ip: ip)
        DVMLog.log(phase: .mounting, "mounting \(remainingMounts.count) VirtioFS shares (nix-store handled by image)")
        tprint("Mounting VirtioFS shares...")

        // Build mount script and execute via gRPC Exec.
        //
        // Home mounts (guest paths under /Users/admin) use symlinks instead of
        // direct VirtioFS mounts. macOS VirtioFS has a kernel-level bug where
        // nested mounts (VirtioFS inside VirtioFS) silently fail: mount_virtiofs
        // succeeds and appears in `mount` output, but reads/writes fall through
        // to the parent mount due to vnode identity instability in AppleVirtIOFS.
        // See: docs/research/macos-virtiofs-nested-mount-failure.md
        //
        // Instead, we mount at /var/dvm-mounts/<tag> (not nested inside dvm-home)
        // and create a symlink from the guest path. The symlink persists in the
        // dvm-home backing store across reboots. On subsequent boots, the symlink
        // already exists and becomes valid once the VirtioFS device is mounted.
        //
        // The pwd-resolution trade-off (symlinks resolve in pwd) only matters for
        // project directories (mirror mounts), not config dirs like .claude/.codex.
        // Mirror mounts are NOT under /Users/admin, so they're unaffected.
        //
        // NOTE: home mounts currently come from config.toml (opaque to nix).
        // hjem (nix home manager) also manages paths under ~/. If both manage
        // the same path, the symlink will conflict with hjem's managed content.
        // There's no nix-level assertion for this yet — requires migrating home
        // mounts to nix config (bean nix-darvm-xuus).
        let dvmMountsDir = "/var/dvm-mounts"
        var setupLines: [String] = ["mkdir -p \(shellQuote(dvmMountsDir))"]
        var mountFunctions: [String] = []
        var mountCalls: [String] = []
        for mount in remainingMounts {
            let (tag, path): (MountTag, AbsolutePath) = switch mount {
            case .exact(let tag, _, let guestPath, _): (tag, guestPath)
            }
            let t = shellQuote(tag.rawValue)
            let isNestedInHome = path.rawValue.hasPrefix(guestHome + "/")

            // For paths inside /Users/admin (dvm-home VirtioFS), mount at a
            // non-nested path and symlink. For all other paths, mount directly.
            let mountPath: String
            if isNestedInHome {
                let indirectPath = "\(dvmMountsDir)/\(tag.rawValue)"
                mountPath = shellQuote(indirectPath)
                setupLines.append("mkdir -p \(mountPath)")
                // Replace any existing directory with a symlink. If the path is
                // already a symlink, ln -sfn updates it. If it's a directory (stale
                // content from a previous session), warn and skip — user must clean
                // it up manually.
                let p = shellQuote(path.rawValue)
                let parentDir = shellQuote((path.rawValue as NSString).deletingLastPathComponent)
                setupLines.append("mkdir -p \(parentDir)")
                setupLines.append("""
                if [ -L \(p) ]; then ln -sfn \(mountPath) \(p); \
                elif [ -d \(p) ]; then \
                  if [ -z \"$(ls -A \(p) 2>/dev/null)\" ]; then rmdir \(p) && ln -sfn \(mountPath) \(p); \
                  else echo \"WARNING: \(p) is a non-empty directory, expected symlink. Remove it manually: rm -rf \(p)\" >&2; fi; \
                else ln -sfn \(mountPath) \(p); fi
                """)
            } else {
                let p = shellQuote(path.rawValue)
                mountPath = p
                setupLines.append("[ -L \(p) ] && rm -f \(p); mkdir -p \(p)")
            }

            let funcName = "mount_\(tag.rawValue.replacingOccurrences(of: "-", with: "_"))"
            mountFunctions.append("""
            \(funcName)() {
              if /sbin/mount | grep -q " on \(mountPath) "; then
                echo "  \(t) -> \(mountPath) (already mounted)"; return 0
              fi
              for i in 1 2 3 4 5; do
                ERR=$(/sbin/mount_virtiofs \(t) \(mountPath) 2>&1) && { echo "  \(t) -> \(mountPath)"; return 0; }
                case "$ERR" in *"Resource busy"*) echo "  \(t) -> \(mountPath)"; return 0;; esac
                sleep 1
              done
              echo "  \(t) -> \(mountPath) (FAILED: $ERR)" >&2; return 1
            }
            """)
            mountCalls.append("\(funcName) & PIDS=\"$PIDS $!\"")
        }

        let waitBlock = [
            "FAIL=0",
            "for pid in $PIDS; do wait $pid || FAIL=1; done",
        ]
        var scriptParts: [String] = setupLines
        scriptParts.append("PIDS=\"\"")
        scriptParts += mountFunctions
        scriptParts += mountCalls
        scriptParts += waitBlock
        scriptParts.append("exit $FAIL")
        let scriptBody = scriptParts.joined(separator: "\n")

        let mountExitCode = try await agentClient.exec(
            command: ["sudo", "sh", "-c", scriptBody]
        )
        if mountExitCode != 0 {
            DVMLog.log(phase: .mounting, level: "error", "one or more VirtioFS mounts failed")
            tprint("ERROR: One or more VirtioFS mounts failed.")
        } else {
            DVMLog.log(phase: .mounting, "all mounts succeeded")
        }

        // Restart nix daemon bridge in guest — it may have failed at boot
        // because /nix/store wasn't mounted yet (VirtioFS).
        // The agent binary is at /usr/local/bin so it was available at boot,
        // but the bridge dials vsock host:6174 which may not have been ready.
        tprint("Restarting nix daemon bridge...")
        _ = try await agentClient.exec(
            command: ["sudo", "launchctl", "bootout", "system/com.darvm.agent-bridge"]
        )
        _ = try await agentClient.exec(
            command: ["sudo", "launchctl", "bootstrap", "system",
                      "/Library/LaunchDaemons/com.darvm.agent-bridge.plist"]
        )

        // Activation is handled by the in-image activator daemon (WatchPaths).
        // It already ran (or is running) before the agent came up.
        // Placeholder env vars are delivered per-process via the gRPC Exec protocol's
        // environment field, not via guest-global state. See AgentClient.exec(env:).

        // Install MITM CA in guest trust store so HTTPS interception works.
        // Always install — credentials are pushed later at exec time.
        if !caCertPEM.isEmpty {
            let certScript = """
            printf '%s' \(shellQuote(caCertPEM)) > /tmp/dvm-ca.pem && \
            security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/dvm-ca.pem && \
            rm -f /tmp/dvm-ca.pem
            """
            let caInstallCode = try await agentClient.exec(
                command: ["sudo", "sh", "-c", certScript]
            )
            if caInstallCode != 0 {
                DVMLog.log(level: "warn", "failed to install MITM CA in guest trust store")
                tprint("Warning: failed to install CA cert in guest. HTTPS interception may not work.")
            } else {
                DVMLog.log(phase: .activating, "installed MITM CA in guest trust store")
                tprint("MITM CA installed in guest trust store.")
            }

            // NODE_EXTRA_CA_CERTS for Node.js (uses OpenSSL, not macOS Keychain)
            let nodeCAScript = """
            printf '%s' \(shellQuote(caCertPEM)) > /etc/dvm-ca.pem && \
            chmod 644 /etc/dvm-ca.pem
            """
            _ = try await agentClient.exec(command: ["sudo", "sh", "-c", nodeCAScript])
            DVMLog.log(phase: .activating, "wrote CA cert to /etc/dvm-ca.pem for NODE_EXTRA_CA_CERTS")
        }

        // Phase: running
        controlSocket.update(.running, ip: ip)
        DVMLog.log(phase: .running, "VM running at \(ip)")

        // Register credential loading handler for `dvm exec` credential push
        controlSocket.loadCredentialsHandler = { [netstackSupervisor] projectName, secretDicts in
            do {
                var secrets: [ResolvedSecret] = []
                for (i, dict) in secretDicts.enumerated() {
                    guard let name = dict["name"] as? String,
                          let placeholder = dict["placeholder"] as? String,
                          let value = dict["value"] as? String,
                          let hosts = dict["hosts"] as? [String] else {
                        return "loadCredentials: secret at index \(i) has missing or invalid fields"
                    }
                    secrets.append(ResolvedSecret(
                        name: name, placeholder: placeholder,
                        value: value, hosts: hosts))
                }
                try netstackSupervisor.loadCredentials(
                    projectName: projectName, secrets: secrets)
                return nil  // success
            } catch {
                return "\(error)"
            }
        }

        // Register guest health handler for `dvm status` queries
        controlSocket.guestHealthHandler = { [agentClient] in
            final class Box: @unchecked Sendable {
                var value: GuestHealthPayload?
            }
            let box = Box()
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                if let status = try? await agentClient.status() {
                    box.value = GuestHealthPayload(
                        mounts: status.mounts,
                        activation: status.activation,
                        services: status.services.reduce(into: [:]) { $0[$1.key] = $1.value }
                    )
                }
                semaphore.signal()
            }
            let waitResult = semaphore.wait(timeout: .now() + 5)
            guard waitResult == .success else { return nil }
            return box.value
        }

        tprint("VM running. Press Ctrl-C to stop.")
        await runner.waitUntilStopped()
        controlSocket.update(.stopped)
        DVMLog.log(phase: .stopped, "VM stopped")

        // Shut down sidecar before cleanup
        DVMLog.log(phase: .stopped, "shutting down dvm-netstack")
        netstackSupervisor.shutdown()

        controlSocket.cleanup()
        agentProxy.cleanup()
        // Keep hostCmdBridge alive until VM stops (vsock listener needs the object)
        withExtendedLifetime(hostCmdBridge) {}
        tprint("VM stopped.")
    }
}

// MARK: - ConfigGet

struct ConfigGet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config-get",
        abstract: "Read a value from config.toml"
    )

    @Argument(help: "Config key to read (e.g. flake)")
    var key: String

    func run() throws {
        let config = try DVMConfig.load()
        switch key {
        case "flake":
            guard let flake = config.flake else { throw ExitCode(1) }
            print(flake)
        default:
            throw ExitCode(1)
        }
    }
}

// MARK: - ReloadCapabilities

struct ReloadCapabilities: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload-capabilities",
        abstract: "Hot-reload the host action bridge's capabilities manifest"
    )

    @Option(name: .long, help: "Path to capabilities.json manifest (must be in /nix/store/)")
    var path: String

    func run() throws {
        if let error = ControlSocket.sendReloadCapabilities(path: path) {
            fputs("Error: \(error)\n", stderr)
            throw ExitCode(1)
        }
    }
}

// MARK: - Stop

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Gracefully shut down the VM"
    )

    func run() async throws {
        let agentClient = AgentClient()
        do {
            print("Shutting down VM...")
            _ = try await agentClient.exec(
                command: ["sudo", "shutdown", "-h", "now"]
            )
        } catch {
            // Fallback: try control socket to check if running at all
            if case .failure(.socketNotFound) = ControlSocket.send(.status) {
                print("VM not running.")
            } else {
                print("Shutdown command failed: \(error)")
            }
        }
    }
}

// MARK: - Credential Resolution (exec/ssh time)

/// Discover, parse, resolve, and push credentials to the sidecar.
/// Returns env vars to inject into the guest session (placeholder values).
/// Returns empty dict if no manifest is found.
/// Discover the credential manifest path based on the priority chain:
/// `--credentials` flag > `DVM_CREDENTIALS` env > `.dvm/credentials.toml` in cwd.
/// Returns nil if no manifest is found (CWD fallback only).
/// Explicit sources (flag, env var) that point to missing files throw.
func discoverManifestPath(
    credentialsFlag: String?,
    cwd: String
) throws -> String? {
    if let flag = credentialsFlag {
        // Explicit flag — resolve relative to host cwd, fail loudly if missing
        let resolved = URL(fileURLWithPath: flag, relativeTo: URL(fileURLWithPath: cwd))
            .standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw SecretConfigError.manifestNotFound(resolved)
        }
        return resolved
    } else if let envPath = ProcessInfo.processInfo.environment["DVM_CREDENTIALS"] {
        // Explicit env var — empty = error, missing file = error
        guard !envPath.isEmpty else {
            throw SecretConfigError.manifestNotFound(
                "DVM_CREDENTIALS is set but empty")
        }
        let resolved = URL(fileURLWithPath: envPath, relativeTo: URL(fileURLWithPath: cwd))
            .standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw SecretConfigError.manifestNotFound(resolved)
        }
        return resolved
    } else {
        // CWD discovery — no walking, silent skip if not found
        let cwdManifest = (cwd as NSString).appendingPathComponent(".dvm/credentials.toml")
        return FileManager.default.fileExists(atPath: cwdManifest) ? cwdManifest : nil
    }
}

private func resolveAndPushCredentials(
    credentialsFlag: String?,
    cwd: String
) throws -> [String: String] {
    // Explicit sources (--credentials flag, DVM_CREDENTIALS env var) fail hard —
    // the user asked for credentials and they must resolve.
    // CWD auto-discovery (.dvm/credentials.toml) warns and continues —
    // the user didn't ask for credentials, so don't block their command.
    let explicit = credentialsFlag != nil
        || ProcessInfo.processInfo.environment["DVM_CREDENTIALS"] != nil

    guard let path = try discoverManifestPath(
        credentialsFlag: credentialsFlag, cwd: cwd) else {
        return [:]  // no manifest, no credentials — session runs without injection
    }

    do {
        let manifest = try CredentialManifest.load(from: path)
        let hostKey = try HostKey.loadOrCreate()
        let secrets = try manifest.resolve(hostKey: hostKey)

        // Always push — even empty secrets list clears previous mappings for this project.
        if let error = ControlSocket.sendLoadCredentials(
            projectName: manifest.project, secrets: secrets) {
            throw CredentialPushError(detail: error)
        }

        // Build env vars: ENV_VAR_NAME=placeholder for guest injection
        var env: [String: String] = [:]
        for secret in secrets {
            env[secret.name] = secret.placeholder
        }
        return env
    } catch {
        if explicit { throw error }
        fputs("Warning: credential resolution failed, running without injection: \(error)\n", stderr)
        return [:]
    }
}

/// Error pushing credentials to the sidecar via the control socket.
struct CredentialPushError: Error, CustomStringConvertible {
    let detail: String
    var description: String { "Failed to push credentials to proxy: \(detail)" }
}

// MARK: - Exec

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in the VM"
    )

    @Flag(name: .shortAndLong, help: "Allocate a TTY")
    var tty: Bool = false

    @Option(name: .long, help: "Path to credentials.toml manifest")
    var credentials: String?

    @Argument(help: "Command and arguments to execute")
    var command: [String] = []

    func run() async throws {
        let agentClient = AgentClient()
        let cwd = FileManager.default.currentDirectoryPath

        guard !command.isEmpty else {
            throw CleanExit.helpRequest(self)
        }

        // Resolve credentials and push to sidecar
        let credentialEnv = try resolveAndPushCredentials(
            credentialsFlag: credentials, cwd: cwd)

        let exitCode: Int32
        if tty {
            exitCode = try await agentClient.execInteractive(
                command: command,
                cwd: cwd,
                tty: true,
                env: credentialEnv
            )
        } else {
            exitCode = try await agentClient.exec(
                command: command,
                cwd: cwd,
                env: credentialEnv
            )
        }

        throw ExitCode(exitCode)
    }
}

// MARK: - SSH (interactive shell)

struct SSH: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "Open an interactive shell session to the VM"
    )

    @Option(name: .long, help: "Path to credentials.toml manifest")
    var credentials: String?

    func run() async throws {
        let agentClient = AgentClient()
        let cwd = FileManager.default.currentDirectoryPath

        // Resolve credentials and push to sidecar
        let credentialEnv = try resolveAndPushCredentials(
            credentialsFlag: credentials, cwd: cwd)

        let exitCode = try await agentClient.execInteractive(
            command: ["/bin/zsh", "-l"],
            cwd: cwd,
            tty: true,
            env: credentialEnv
        )
        throw ExitCode(exitCode)
    }
}

// MARK: - Status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show VM status"
    )

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        if json {
            try outputJSON()
        } else {
            try outputHuman()
        }
    }

    private func outputJSON() throws {
        var result: [String: Any] = ["running": false]

        switch ControlSocket.send(.status) {
        case .success(.status(let payload)):
            result["running"] = payload.running
            if let phase = payload.phase { result["phase"] = phase }
            if let ip = payload.ip { result["ip"] = ip }
            if let runId = payload.runId { result["run_id"] = runId }
            if let err = payload.phaseError { result["error"] = err }

            if payload.running && payload.phase == VMPhase.running.rawValue {
                if case .success(.guestHealth(let health)) = ControlSocket.send(.guestHealth, timeout: 5) {
                    result["mounts"] = health.mounts
                    result["activation"] = health.activation
                    result["services"] = health.services
                }
            }
        case .failure:
            break
        default:
            break
        }

        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)

        if result["running"] as? Bool != true {
            throw ExitCode(1)
        }
    }

    private func outputHuman() throws {
        switch ControlSocket.send(.status) {
        case .success(.status(let payload)):
            if !payload.running {
                if let err = payload.phaseError {
                    let phase = payload.phase ?? "unknown"
                    print("VM not running (phase: \(phase), error: \(err))")
                } else {
                    print("VM not running")
                }
                throw ExitCode(1)
            }

            let phase = payload.phase ?? "unknown"
            var elapsed = ""
            if let enteredAt = payload.phaseEnteredAt {
                elapsed = formatElapsed(Date().timeIntervalSince1970 - enteredAt)
            }

            if let ip = payload.ip {
                print("VM running at \(ip) (phase: \(phase), \(elapsed))")
            } else {
                print("VM starting (phase: \(phase), \(elapsed) elapsed)")
            }
            if let runId = payload.runId {
                print("  Run:        \(runId)")
            }

            if payload.phase == VMPhase.running.rawValue {
                switch ControlSocket.send(.guestHealth, timeout: 5) {
                case .success(.guestHealth(let health)):
                    print("  Mounts:     \(health.mounts.count) virtiofs")
                    print("  Activation: \(health.activation)")
                    if !health.services.isEmpty {
                        let svcStr = health.services
                            .sorted(by: { $0.key < $1.key })
                            .map { "\($0.key)=\($0.value)" }
                            .joined(separator: ", ")
                        print("  Services:   \(svcStr)")
                    }
                case .success(.error(let msg)):
                    print("  Guest:      unavailable (\(msg))")
                default:
                    print("  Guest:      unavailable")
                }
            }

        case .success(.error(let message)):
            print("VM not running (server error: \(message))")
            throw ExitCode(1)
        case .success(.guestHealth):
            print("VM not running (unexpected response)")
            throw ExitCode(1)
        case .failure(.socketNotFound):
            print("VM not running")
            throw ExitCode(1)
        case .failure(let error):
            print("VM not running (\(error))")
            throw ExitCode(1)
        }
    }
}
