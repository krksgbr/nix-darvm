import ArgumentParser
import Foundation

/// Default VM name. Overridden by --vm-name when the wrapper passes
/// a content-addressed name (e.g. darvm-a1b2c3d4).
let defaultVMName = "darvm-base"

/// Set by signal handler to interrupt blocking operations (e.g. mount retry loop).
/// Accessed from multiple threads — nonisolated(unsafe) since we only do atomic flag reads/writes.
nonisolated(unsafe) var stopRequested = false

/// Elapsed time since process start, for timestamped log output.
private let processStartTime = CFAbsoluteTimeGetCurrent()
private let consoleOutputLock = NSLock()
nonisolated(unsafe) private var consoleHasLiveLine = false

func consolePrintLine(_ line: String) {
  consoleOutputLock.lock()
  defer { consoleOutputLock.unlock() }

  if consoleHasLiveLine {
    fputs("\n", stdout)
    consoleHasLiveLine = false
  }

  fputs(line + "\n", stdout)
  fflush(stdout)
}

func consoleReplaceLiveLine(_ line: String) {
  consoleOutputLock.lock()
  defer { consoleOutputLock.unlock() }

  if consoleHasLiveLine {
    fputs("\r\u{001B}[2K" + line, stdout)
  } else {
    fputs(line, stdout)
    consoleHasLiveLine = true
  }
  fflush(stdout)
}

func consoleCommitLiveLine() {
  consoleOutputLock.lock()
  defer { consoleOutputLock.unlock() }

  guard consoleHasLiveLine else {
    return
  }

  fputs("\n", stdout)
  fflush(stdout)
  consoleHasLiveLine = false
}

func tprint(_ message: String, tone: ConsoleTone = .plain) {
  let elapsed = CFAbsoluteTimeGetCurrent() - processStartTime
  consolePrintLine(ConsoleStyle.formatTimestampedMessage(elapsed: elapsed, message: message, tone: tone))
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

  static func log(_ msg: String) {
    log(phase: nil, level: "info", msg)
  }

  static func log(phase: VMPhase?, _ msg: String) {
    log(phase: phase, level: "info", msg)
  }

  static func log(level: String, _ msg: String) {
    log(phase: nil, level: level, msg)
  }

  static func log(phase: VMPhase?, level: String, _ msg: String) {
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
    let guestIP = GuestIP(ipAddress)
  {
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
/// HomeLinks are NOT computed here — call `homeLinksForEffectiveMounts` with the post-filter
/// mount list from VMConfigurator to avoid installing links for mounts whose host paths are absent.
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

  // Validate that no user-provided home dir conflicts with reserved local paths,
  // and that all home dirs are strictly inside the host home directory.
  for directory in homeDirs {
    let homeRelative = homeRelativePortion(directory: directory, hostHome: hostHome)
    if homeRelative.hasPrefix("/") {
      throw HomeLinkError.notUnderHome(directory)
    }
    let topLevel = String(homeRelative.prefix { $0 != "/" })
    if HomeRelativePath.reservedLocalPaths.contains(topLevel) {
      throw HomeLinkError.reservedPath(homeRelative)
    }
  }

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

/// Derives HomeLinks from the post-filter effective mounts plus built-in local links.
/// Must be called with `effectiveMounts` from VMConfigurator (after host-path filtering),
/// not with the raw requested mount list, to avoid installing links for absent host paths.
func homeLinksForEffectiveMounts(_ mounts: [MountConfig]) throws -> [HomeLink] {
  var links: [HomeLink] = []
  for mount in mounts {
    if let link = try homeLinkForMount(mount) {
      links.append(link)
    }
  }
  return links
}

private func defaultMounts(hostHome _: String) throws -> [MountConfig] {
  [
    .exact(
      tag: try MountTag("nix-store"),
      hostPath: try AbsolutePath("/nix/store"),
      guestPath: try AbsolutePath("/nix/store"),
      access: .readOnly,
      transport: .virtiofs)
    // Intentionally no built-in `~/.cache/nix` host mount.
    // See DR-008: sharing host↔guest mutable Nix cache state caused real
    // SQLite corruption and broader cache-coherency failures. Keep guest
    // `~/.cache/nix` local unless a future opt-in design proves otherwise.
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

/// Derives a HomeLink from a mount whose guest path is under the guest home.
/// Returns nil for non-home-relative mounts.
func homeLinkForMount(_ mount: MountConfig) throws -> HomeLink? {
  let guestPath = mount.guestPath.rawValue
  guard guestPath.hasPrefix(guestHome + "/") else {
    return nil
  }
  let subpath = String(guestPath.dropFirst(guestHome.count + 1))
  return HomeLink(
    subpath: try HomeRelativePath(subpath),
    target: try AbsolutePath("/var/dvm-mounts/\(mount.tag.rawValue)")
  )
}

/// Extracts the home-relative portion of a directory path. Handles both
/// absolute paths (with host home prefix) and already-relative paths.
private func homeRelativePortion(directory: String, hostHome: String) -> String {
  let expanded = expandTilde(in: directory)
  let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
  if standardized.hasPrefix(hostHome + "/") {
    return String(standardized.dropFirst(hostHome.count + 1))
  }
  return standardized
}

func printStoppedStatus(_ payload: ControlSocket.StatusPayload) throws {
  if let error = payload.phaseError {
    let phase = payload.phase ?? "unknown"
    print("VM not running (phase: \(phase), error: \(error))")
  } else {
    print("VM not running")
  }
  throw ExitCode(1)
}

func statusSummaryLine(_ payload: ControlSocket.StatusPayload) -> String {
  let phase = payload.phase ?? "unknown"
  let elapsed =
    payload.phaseEnteredAt.map { formatElapsed(Date().timeIntervalSince1970 - $0) } ?? ""

  if let ipAddress = payload.ipAddress {
    return "VM running at \(ipAddress) (phase: \(phase), \(elapsed))"
  }
  return "VM starting (phase: \(phase), \(elapsed) elapsed)"
}

func printGuestHealthSummary() {
  switch ControlSocket.send(.guestHealth, timeout: 5) {
  case .success(.guestHealth(let health)):
    printMountsBlock(builtIn: health.builtInMounts, configured: health.mounts)
    print("  Activation: \(health.activation)")
    if !health.services.isEmpty {
      let serviceSummary = health.services
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ", ")
      print("  Services:   \(serviceSummary)")
    }
    if !health.forwardedPorts.isEmpty {
      let portList = health.forwardedPorts.map(String.init).joined(separator: ", ")
      print("  Ports:      \(portList)")
    }
    if !health.portConflicts.isEmpty {
      let conflictList = health.portConflicts.map { "\($0) (host in use)" }.joined(separator: ", ")
      print("  Conflicts:  \(conflictList)")
    }

  case .success(.error(let message)):
    print("  Guest:      unavailable (\(message))")

  default:
    print("  Guest:      unavailable")
  }
}

private func printMountsBlock(builtIn: [String], configured: [String]) {
  // "  Mounts:   " = 12 chars; continuation lines use the same indent.
  let prefix = "  Mounts:   "
  let indent = String(repeating: " ", count: prefix.count)

  print("\(prefix)---- Built-in ----")
  print("")
  for mount in builtIn { print("\(indent)\(mount)") }
  print("")
  print("\(indent)---- Configured ----")
  print("")
  for mount in configured { print("\(indent)\(mount)") }
}

func throwStatusFailure(_ result: Result<ControlSocket.Response, ControlSocket.ClientError>) throws -> Never {
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
