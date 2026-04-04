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
    let milliseconds = Int((elapsed - Double(secs)) * 1_000)
    print(String(format: "[%3d.%03ds] %@", secs, milliseconds, message))
}

// MARK: - Structured logging

/// Structured JSON logger for DVM. Writes JSON lines to /tmp/dvm-<pid>.log.
/// In debug mode, also emits to stderr.
enum DVMLog {
    /// Unique run identifier, shared with VMStatus.
    static let runId: String = {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<8).compactMap { _ in chars.randomElement() })
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
            "run_id": runId
        ]
        if let phase { entry["phase"] = phase.rawValue }

        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let lineWithNewline = line + "\n"

        logHandle?.write(Data(lineWithNewline.utf8))

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
        subcommands: [
            Start.self, Stop.self, Exec.self, SSH.self, Status.self, ConfigGet.self,
            ReloadCapabilities.self
        ]
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
       let ipAddress = payload.ipAddress,
       let guestIP = GuestIP(ipAddress) {
        return guestIP
    }

    // Fallback to DHCP lease (control socket may not be running, e.g. Tart-managed VM)
    let configURL = vmDir().appendingPathComponent("config.json")
    let config = try TartConfig(fromURL: configURL)
    guard let guestIP = DHCPLeaseParser.getIPAddress(forMAC: config.macAddress.string) else {
        throw DVMError.noIPAddress
    }
    return guestIP
}

func shellQuote(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Guest user home. The base image has user "admin" with UID 501.
let guestHome = "/Users/admin"

/// Build mount configs from mirror, home, and system directory lists.
///
/// - mirror dirs: mounted at the same absolute path in the guest via NFS (project dirs, read-write)
/// - home dirs: mounted relative to the guest user's home (config/data dirs, read-write)
/// - system dirs: mounted at the same absolute path in the guest (toolchains, read-only)
///
/// WARNING: Do NOT mount ~/.config/dvm — it contains user configuration.
/// A writable mount would let a rogue guest modify host settings.
func buildMounts(
    hostHome: String,
    mirrorDirs: [String],
    mirrorTransport: MountTransport?,
    homeDirs: [String],
    systemDirs: [String] = []
) throws -> [MountConfig] {
    var mounts = try defaultMounts(hostHome: hostHome)
    let resolvedMirrorTransport = try resolveMirrorTransport(
        mirrorDirs: mirrorDirs,
        mirrorTransport: mirrorTransport
    )

    for (index, directory) in mirrorDirs.enumerated() {
        mounts.append(
            try makeMirrorMount(
                index: index,
                directory: directory,
                transport: resolvedMirrorTransport
            )
        )
    }

    for (index, directory) in homeDirs.enumerated() {
        mounts.append(try makeHomeMount(index: index, directory: directory, hostHome: hostHome))
    }

    // System dirs: same absolute path in guest, read-only.
    // Used for host toolchains (Xcode, developer tools) that should be
    // shared immutably — enforced at the VirtioFS device level (EROFS).
    for (index, directory) in systemDirs.enumerated() {
        mounts.append(try makeSystemMount(index: index, directory: directory))
    }

    return mounts
}

private func defaultMounts(hostHome: String) throws -> [MountConfig] {
    [
        .exact(
            tag: try MountTag("nix-store"),
            hostPath: try AbsolutePath("/nix/store"),
            guestPath: try AbsolutePath("/nix/store"),
            access: .readOnly,
            transport: .virtiofs),
        .exact(
            tag: try MountTag("nix-cache"),
            hostPath: try AbsolutePath("\(hostHome)/.cache/nix"),
            guestPath: try AbsolutePath("\(guestHome)/.cache/nix"),
            access: .readWrite,
            transport: .virtiofs)
    ]
}

private func resolveMirrorTransport(
    mirrorDirs: [String],
    mirrorTransport: MountTransport?
) throws -> MountTransport {
    if mirrorDirs.isEmpty {
        return .nfs
    }
    guard let mirrorTransport else {
        throw ConfigError.missingKey(key: "transport", section: "mounts.mirror")
    }
    return mirrorTransport
}

private func makeMirrorMount(
    index: Int,
    directory: String,
    transport: MountTransport
) throws -> MountConfig {
    let resolved = expandTilde(in: directory)
    let standardizedPath = URL(fileURLWithPath: resolved).standardizedFileURL.path
    return .exact(
        tag: try MountTag("mirror-\(index)"),
        hostPath: try AbsolutePath(standardizedPath),
        guestPath: try AbsolutePath(standardizedPath),
        access: .readWrite,
        transport: transport
    )
}

private func makeHomeMount(index: Int, directory: String, hostHome: String) throws -> MountConfig {
    let expandedDirectory = expandTilde(in: directory)
    let hostPath = URL(fileURLWithPath: expandedDirectory).standardizedFileURL.path
    let guestPath: String
    if hostPath.hasPrefix(hostHome) {
        guestPath = guestHome + hostPath.dropFirst(hostHome.count)
    } else {
        guestPath = hostPath
    }
    return .exact(
        tag: try MountTag("home-\(index)"),
        hostPath: try AbsolutePath(hostPath),
        guestPath: try AbsolutePath(guestPath),
        access: .readWrite,
        transport: .virtiofs
    )
}

private func makeSystemMount(index: Int, directory: String) throws -> MountConfig {
    let resolved = URL(fileURLWithPath: directory).standardizedFileURL.path
    return .exact(
        tag: try MountTag("system-\(index)"),
        hostPath: try AbsolutePath(resolved),
        guestPath: try AbsolutePath(resolved),
        access: .readOnly,
        transport: .virtiofs
    )
}

private func printStoppedStatus(_ payload: ControlSocket.StatusPayload) throws {
    if let error = payload.phaseError {
        let phase = payload.phase ?? "unknown"
        print("VM not running (phase: \(phase), error: \(error))")
    } else {
        print("VM not running")
    }
    throw ExitCode(1)
}

private func statusSummaryLine(_ payload: ControlSocket.StatusPayload) -> String {
    let phase = payload.phase ?? "unknown"
    let elapsed =
        payload.phaseEnteredAt.map { formatElapsed(Date().timeIntervalSince1970 - $0) } ?? ""

    if let ipAddress = payload.ipAddress {
        return "VM running at \(ipAddress) (phase: \(phase), \(elapsed))"
    }
    return "VM starting (phase: \(phase), \(elapsed) elapsed)"
}

private func printGuestHealthSummary() {
    switch ControlSocket.send(.guestHealth, timeout: 5) {
    case .success(.guestHealth(let health)):
        print("  Mounts:     \(health.mounts.count) virtiofs")
        print("  Activation: \(health.activation)")
        if !health.services.isEmpty {
            let serviceSummary = health.services
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            print("  Services:   \(serviceSummary)")
        }

    case .success(.error(let message)):
        print("  Guest:      unavailable (\(message))")

    default:
        print("  Guest:      unavailable")
    }
}

private func throwStatusFailure(_ result: Result<ControlSocket.Response, ControlSocket.ClientError>) throws -> Never {
    switch result {
    case .success(.error(let message)):
        print("VM not running (server error: \(message))")

    case .success(.guestHealth):
        print("VM not running (unexpected response)")

    case .failure(.socketNotFound):
        print("VM not running")

    case .failure(let error):
        print("VM not running (\(error))")

    case .success(.status):
        fatalError("throwStatusFailure should not be called with a status response")
    }
    throw ExitCode(1)
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

    @Option(
        name: .long, parsing: .upToNextOption,
        help: "Home-mount directories (relative to guest user's home)")
    var homeDir: [String] = []

    @Option(
        name: .long, parsing: .upToNextOption,
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
        configureLogging()
        let prepared = try prepareStartContext()
        let configured = try configureRuntime(using: prepared)
        let running = try await startRuntime(prepared: prepared, configured: configured)
        defer { removeManagedExports(running.nfsExportManager) }

        try await restartGuestBridgeAndInstallCA(
            agentClient: running.services.agentClient,
            caCertPEM: configured.caCertPEM
        )
        registerRuntimeHandlers(
            controlSocket: prepared.controlSocket,
            services: running.services,
            netstackSupervisor: prepared.netstackSupervisor
        )
        await finishRunningSession(
            guestIP: running.guestIP,
            controlSocket: prepared.controlSocket,
            services: running.services,
            netstackSupervisor: prepared.netstackSupervisor,
            runner: configured.runner
        )

        withExtendedLifetime(running.signalSources) {
            // Keep signal sources alive until the running session is torn down.
        }
        withExtendedLifetime(running.services.vsockBridge) {
            // Keep the bridge alive until teardown completes.
        }
        withExtendedLifetime(running.services.hostCommandBridgeBox) {
            // Keep the command bridge alive until teardown completes.
        }
    }
}
