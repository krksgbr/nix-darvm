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
        subcommands: [Start.self, Stop.self, Exec.self, SSH.self, Status.self, ConfigGet.self]
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

/// Build mount configs from mirror and home directory lists.
///
/// - mirror dirs: mounted at the same absolute path in the guest (project dirs)
/// - home dirs: mounted relative to the guest user's home (config/data dirs)
///
/// WARNING: Do NOT mount ~/.config/dvm — it contains the host command allowlist.
/// A writable mount would let a rogue guest escalate to arbitrary host execution.
func buildMounts(hostHome: String, mirrorDirs: [String], homeDirs: [String]) throws -> [MountConfig] {
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

    var description: String {
        switch self {
        case .noIPAddress: return "Could not resolve VM IP address. Is the VM running?"
        case .buildFailed: return "nix build failed"
        case .invalidStorePath(let s): return "Invalid nix store path from build output: \(s)"
        case .activationFailed(let msg): return "Activation failed: \(msg)"
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

    @Option(name: .long, help: "Nix store path to the desired nix-darwin system closure")
    var systemClosure: String?

    @Flag(name: .long, help: "Verbose output: structured logs + guest log streaming")
    var debug: Bool = false

    @Option(name: .long, help: "Custom macOS log predicate for guest log streaming (implies --debug)")
    var logPredicate: String?

    @Option(name: .long, help: "Tart VM name")
    var vmName: String?

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
            homeDirs: config.homeDirs + homeDir
        )

        // Control socket for CLI coordination (status, stop, etc.)
        let controlSocket = ControlSocket()
        try controlSocket.listen()

        // Phase: configuring
        let effectiveVMName = vmName ?? defaultVMName
        let vmDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tart/vms/\(effectiveVMName)")
        controlSocket.update(.configuring)
        DVMLog.log(phase: .configuring, "configuring VM from \(vmDirectory.path)")
        tprint("Configuring VM from \(vmDirectory.path)...")

        // Credential proxy: discover manifests, resolve secrets, launch sidecar
        // Scan both config-file mirror dirs AND CLI --dir args for credentials.toml
        let credentialPaths = config.credentialManifestPaths(additionalDirs: dir)
        var netstackSupervisor: NetstackSupervisor?
        var resolvedProjects: [(project: String, secrets: [ResolvedSecret])] = []
        var caCertPEM = ""

        if !credentialPaths.isEmpty {
            DVMLog.log(phase: .configuring, "loading credential manifests from \(credentialPaths.count) project(s)")
            for (project, manifestPath) in credentialPaths {
                let manifest = try CredentialManifest.load(from: manifestPath)
                let secrets = try SecretResolver.resolve(manifest)
                try HostOverlapChecker.check(
                    existing: resolvedProjects,
                    newProject: project,
                    newSecrets: secrets
                )
                resolvedProjects.append((project: project, secrets: secrets))
                DVMLog.log(phase: .configuring,
                           "resolved \(secrets.count) secret(s) for \(project)")
            }

            let totalSecrets = resolvedProjects.flatMap(\.secrets)
            tprint("Credentials: \(totalSecrets.count) secret(s) from \(credentialPaths.count) project(s)")

            // CA is generated by the sidecar in Go (more reliable than Swift DER builder).
            // We send empty PEMs; the sidecar generates the CA and returns the PEM
            // in the ready response for guest trust store installation.
            let caKeyPEM = ""
            DVMLog.log(phase: .configuring, "CA will be generated by sidecar")

            // Resolve sidecar binary path
            let netstackBinary = ProcessInfo.processInfo.environment["DVM_NETSTACK"]
                ?? "/usr/local/bin/dvm-netstack"

            let netstackConfig = NetstackSupervisor.Config(
                netstackBinary: netstackBinary,
                subnet: "192.168.64.0/24",
                gatewayIP: "192.168.64.1",
                guestIP: "192.168.64.2",
                dnsServers: ["8.8.8.8", "8.8.4.4"],
                caCertPEM: caCertPEM,
                caKeyPEM: caKeyPEM,
                secrets: totalSecrets
            )

            let supervisor = try NetstackSupervisor.launch(
                config: netstackConfig,
                onCrash: {
                    DVMLog.log(level: "error", "dvm-netstack crashed — networking is down, failing closed")
                    tprint("FATAL: Credential proxy (dvm-netstack) crashed. VM networking is down.")
                }
            )

            try supervisor.configure(config: netstackConfig)
            caCertPEM = supervisor.caCertPEM
            DVMLog.log(phase: .configuring, "dvm-netstack sidecar ready (CA: \(caCertPEM.isEmpty ? "none" : "\(caCertPEM.count) bytes"))")
            supervisor.startMonitoring()
            tprint("Credential proxy started.")
            netstackSupervisor = supervisor
        }

        // Create state directory for host↔guest activation state exchange.
        // Shared via VirtioFS as "dvm-state", mounted at /var/run/dvm-state in guest.
        let stateDir = URL(fileURLWithPath:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state/dvm").path)
        // Clean up stale state from previous runs
        try? FileManager.default.removeItem(at: stateDir)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        DVMLog.log(phase: .configuring, "state dir: \(stateDir.path)")

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
            netstackFD: netstackSupervisor?.vmFD,
            stateDir: stateDir
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

        // Host command bridge: forward allowed commands from guest → host
        let hostCmdBridge: HostCommandBridge?
        if !config.hostCommands.isEmpty {
            hostCmdBridge = try HostCommandBridge(
                vm: runner.vm,
                allowedCommands: Set(config.hostCommands)
            )
            hostCmdBridge!.start()
        } else {
            hostCmdBridge = nil
        }

        let agentClient = AgentClient()

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
        // nix-store is already mounted by the image's mount script at boot.
        // Mount remaining shares (nix-cache, mirror dirs, home dirs) via gRPC.
        let remainingMounts = effectiveMounts.filter { mount in
            guard case .exact(let tag, _, _, _) = mount else { return false }
            return tag.rawValue != "nix-store"
        }
        controlSocket.update(.mounting, ip: ip)
        DVMLog.log(phase: .mounting, "mounting \(remainingMounts.count) VirtioFS shares (nix-store handled by image)")
        tprint("Mounting VirtioFS shares...")

        // Build mount script and execute via gRPC Exec
        var setupLines: [String] = []
        var mountFunctions: [String] = []
        var mountCalls: [String] = []
        for mount in remainingMounts {
            let (tag, path): (MountTag, AbsolutePath) = switch mount {
            case .exact(let tag, _, let guestPath, _): (tag, guestPath)
            }
            let t = shellQuote(tag.rawValue)
            let p = shellQuote(path.rawValue)
            setupLines.append("[ -L \(p) ] && rm -f \(p); mkdir -p \(p)")

            let funcName = "mount_\(tag.rawValue.replacingOccurrences(of: "-", with: "_"))"
            mountFunctions.append("""
            \(funcName)() {
              if /sbin/mount | grep -q " on \(p) "; then
                echo "  \(t) -> \(p) (already mounted)"; return 0
              fi
              for i in 1 2 3 4 5; do
                ERR=$(/sbin/mount_virtiofs \(t) \(p) 2>&1) && { echo "  \(t) -> \(p)"; return 0; }
                case "$ERR" in *"Resource busy"*) echo "  \(t) -> \(p)"; return 0;; esac
                sleep 1
              done
              echo "  \(t) -> \(p) (FAILED: $ERR)" >&2; return 1
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

        // Create host command symlinks in guest
        if !config.hostCommands.isEmpty {
            tprint("Setting up host command forwarding...")
            let symlinkScript = config.hostCommands.map { cmd in
                "ln -sf /run/current-system/sw/bin/dvm-host-cmd /usr/local/bin/\(shellQuote(cmd))"
            }.joined(separator: "\n")
            let symlinkCode = try await agentClient.exec(
                command: ["sudo", "sh", "-c", symlinkScript]
            )
            if symlinkCode != 0 {
                DVMLog.log(phase: .mounting, level: "warn", "failed to create host command symlinks")
                tprint("Warning: failed to create host command symlinks.")
            } else {
                DVMLog.log(phase: .mounting, "host command symlinks: \(config.hostCommands.joined(separator: ", "))")
            }
        }

        // Activation is handled by the in-image activator daemon (WatchPaths).
        // It already ran (or is running) before the agent came up.
        // Placeholder env vars are delivered per-process via the gRPC Exec protocol's
        // environment field, not via guest-global state. See AgentClient.exec(env:).

        // Install MITM CA in guest trust store so HTTPS interception works.
        if !resolvedProjects.isEmpty {
            // macOS System Keychain trust
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
        if let supervisor = netstackSupervisor {
            DVMLog.log(phase: .stopped, "shutting down dvm-netstack")
            supervisor.shutdown()
        }

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

// MARK: - Exec

struct Exec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in the VM"
    )

    @Flag(name: .shortAndLong, help: "Allocate a TTY")
    var tty: Bool = false

    @Argument(help: "Command and arguments to execute")
    var command: [String] = []

    func run() async throws {
        let agentClient = AgentClient()
        let cwd = FileManager.default.currentDirectoryPath

        guard !command.isEmpty else {
            throw CleanExit.helpRequest(self)
        }

        let exitCode: Int32
        if tty {
            exitCode = try await agentClient.execInteractive(
                command: command,
                cwd: cwd,
                tty: true
            )
        } else {
            exitCode = try await agentClient.exec(
                command: command,
                cwd: cwd
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

    func run() async throws {
        let agentClient = AgentClient()
        let cwd = FileManager.default.currentDirectoryPath

        let exitCode = try await agentClient.execInteractive(
            command: ["/bin/zsh", "-l"],
            cwd: cwd,
            tty: true
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
