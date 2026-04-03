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
  let milliseconds = Int((elapsed - Double(secs)) * 1000)
  print(String(format: "[%3d.%03ds] %@", secs, milliseconds, message))
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
      "run_id": runId
    ]
    if let phase { entry["phase"] = phase.rawValue }

    guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
      let line = String(data: data, encoding: .utf8)
    else { return }
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
  let resolved = URL(
    fileURLWithPath: (directory as NSString).expandingTildeInPath
  ).standardizedFileURL.path
  return .exact(
    tag: try MountTag("mirror-\(index)"),
    hostPath: try AbsolutePath(resolved),
    guestPath: try AbsolutePath(resolved),
    access: .readWrite,
    transport: transport
  )
}

private func makeHomeMount(index: Int, directory: String, hostHome: String) throws -> MountConfig {
  let hostPath = URL(
    fileURLWithPath: (directory as NSString).expandingTildeInPath
  ).standardizedFileURL.path
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
        .sorted(by: { $0.key < $1.key })
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
    case .invalidStorePath(let storePath):
      return "Invalid nix store path from build output: \(storePath)"
    case .activationFailed(let msg): return "Activation failed: \(msg)"
    case .alreadyRunning:
      return "A VM is already running. Stop it first or use `dvm switch` to apply changes."
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

private struct PreparedStartContext {
  let controlSocket: ControlSocket
  let vmDirectory: URL
  let mounts: [MountConfig]
  let netstackSupervisor: NetstackSupervisor
  let stateDir: URL
  let homeDataDir: URL
  let netstackBinary: String
}

private struct ConfiguredStartContext {
  let runner: VMRunner
  let effectiveMounts: [MountConfig]
  let nfsMACAddress: VZMACAddress?
  let caCertPEM: String
}

private struct StartedGuestServices {
  let vsockBridge: VsockDaemonBridge
  let agentProxy: AgentProxy
  let agentClient: AgentClient
  let hostCommandBridgeBox: HostCommandBridgeBox
}

private struct SignalSources {
  let sigintSource: DispatchSourceSignal
  let sigtermSource: DispatchSourceSignal
}

private struct BootErrorMonitor {
  let bootErrorFile: URL

  init(stateDir: URL) {
    bootErrorFile = stateDir.appendingPathComponent("boot-error")
  }

  func currentError() -> String? {
    guard
      let error = try? String(contentsOf: bootErrorFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !error.isEmpty
    else { return nil }
    return error
  }
}

private final class HostCommandBridgeBox: @unchecked Sendable {
  var bridge: HostCommandBridge?
}

private enum ActivationPollResult {
  case pending
  case succeeded
  case failed
}

private struct RuntimeMountPreparation {
  let nfsMirrorMounts: [MountConfig]
  let nfsHostIP: GuestIP?
  let nfsExportManager: NFSExportManager?
}

private struct RunningStartContext {
  let signalSources: SignalSources
  let services: StartedGuestServices
  let guestIP: GuestIP
  let nfsExportManager: NFSExportManager?
}

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

    withExtendedLifetime(running.signalSources) {}
    withExtendedLifetime(running.services.vsockBridge) {}
    withExtendedLifetime(running.services.hostCommandBridgeBox) {}
  }
}

extension Start {
  fileprivate func configureLogging() {
    let effectiveDebug =
      debug || logPredicate != nil || ProcessInfo.processInfo.environment["DVM_DEBUG"] == "1"
    DVMLog.debugMode = effectiveDebug
    DVMLog.log(phase: .stopped, "dvm starting (run_id=\(DVMLog.runId), log=\(DVMLog.logPath))")
  }

  fileprivate func prepareStartContext() throws -> PreparedStartContext {
    let mounts = try buildConfiguredMounts()
    let controlSocket = try prepareControlSocket()
    let vmDirectory = currentVMDirectory()
    let netstackBinary =
      ProcessInfo.processInfo.environment["DVM_NETSTACK"] ?? "/usr/local/bin/dvm-netstack"
    let netstackSupervisor = try makeNetstackSupervisor(netstackBinary: netstackBinary)
    let stateDir = try makeStateDir()
    let homeDataDir = try makeHomeDataDir(from: stateDir)
    try writeActivationFilesIfNeeded(stateDir: stateDir)
    controlSocket.update(.configuring)
    DVMLog.log(phase: .configuring, "configuring VM from \(vmDirectory.path)")
    tprint("Configuring VM from \(vmDirectory.path)...")
    return PreparedStartContext(
      controlSocket: controlSocket,
      vmDirectory: vmDirectory,
      mounts: mounts,
      netstackSupervisor: netstackSupervisor,
      stateDir: stateDir,
      homeDataDir: homeDataDir,
      netstackBinary: netstackBinary
    )
  }

  fileprivate func buildConfiguredMounts() throws -> [MountConfig] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let config = try DVMConfig.load()
    return try buildMounts(
      hostHome: home,
      mirrorDirs: config.mirrorDirs,
      mirrorTransport: config.mirrorTransport,
      homeDirs: config.homeDirs + homeDir,
      systemDirs: systemDir
    )
  }

  fileprivate func prepareControlSocket() throws -> ControlSocket {
    guard !ControlSocket.isRunning() else {
      throw DVMError.alreadyRunning
    }
    let controlSocket = ControlSocket()
    try controlSocket.listen()
    return controlSocket
  }

  fileprivate func currentVMDirectory() -> URL {
    let effectiveVMName = vmName ?? defaultVMName
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".tart/vms/\(effectiveVMName)")
  }

  fileprivate func makeNetstackSupervisor(netstackBinary: String) throws -> NetstackSupervisor {
    try NetstackSupervisor.launch(
      config: initialNetstackConfig(netstackBinary: netstackBinary),
      onCrash: {
        DVMLog.log(level: "error", "dvm-netstack crashed — networking is down, failing closed")
        tprint("FATAL: Credential proxy (dvm-netstack) crashed. VM networking is down.")
      }
    )
  }

  fileprivate func initialNetstackConfig(netstackBinary: String) -> NetstackSupervisor.Config {
    NetstackSupervisor.Config(
      netstackBinary: netstackBinary,
      subnet: "172.22.0.0/24",
      gatewayIP: "172.22.0.1",
      guestIP: "172.22.0.2",
      guestMAC: "",
      dnsServers: ["8.8.8.8", "8.8.4.4"],
      caCertPEM: "",
      caKeyPEM: ""
    )
  }

  fileprivate func makeStateDir() throws -> URL {
    let dvmLocalDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/state/dvm")
    let stateDir = URL(fileURLWithPath: dvmLocalDir.path)
    try? FileManager.default.removeItem(at: stateDir)
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    DVMLog.log(phase: .configuring, "state dir: \(stateDir.path)")
    return stateDir
  }

  fileprivate func makeHomeDataDir(from stateDir: URL) throws -> URL {
    let homeDataDir =
      stateDir
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("state/dvm/home")
    if !FileManager.default.fileExists(atPath: homeDataDir.path) {
      try FileManager.default.createDirectory(at: homeDataDir, withIntermediateDirectories: true)
      DVMLog.log(phase: .configuring, "created home data dir: \(homeDataDir.path)")
    }
    DVMLog.log(phase: .configuring, "home data dir: \(homeDataDir.path)")
    return homeDataDir
  }

  fileprivate func writeActivationFilesIfNeeded(stateDir: URL) throws {
    guard let closure = systemClosure else { return }
    try closure.write(
      to: stateDir.appendingPathComponent("closure-path"),
      atomically: true,
      encoding: .utf8
    )
    try DVMLog.runId.write(
      to: stateDir.appendingPathComponent("run-id"),
      atomically: true,
      encoding: .utf8
    )
    DVMLog.log(phase: .configuring, "activation requested: \(closure)")
  }

  fileprivate func configureRuntime(using prepared: PreparedStartContext) throws -> ConfiguredStartContext {
    let configured = try VMConfigurator.create(
      vmDir: prepared.vmDirectory,
      mounts: prepared.mounts,
      netstackFD: prepared.netstackSupervisor.vmFD,
      stateDir: prepared.stateDir,
      homeDataDir: prepared.homeDataDir
    )
    let caCertPEM = try configureNetstack(
      configured: configured,
      netstackSupervisor: prepared.netstackSupervisor,
      netstackBinary: prepared.netstackBinary
    )
    return ConfiguredStartContext(
      runner: VMRunner(configured),
      effectiveMounts: configured.effectiveMounts,
      nfsMACAddress: configured.nfsMACAddress,
      caCertPEM: caCertPEM
    )
  }

  fileprivate func configureNetstack(
    configured: ConfiguredVM,
    netstackSupervisor: NetstackSupervisor,
    netstackBinary: String
  ) throws -> String {
    let initialConfig = initialNetstackConfig(netstackBinary: netstackBinary)
    let netstackConfig = NetstackSupervisor.Config(
      netstackBinary: netstackBinary,
      subnet: initialConfig.subnet,
      gatewayIP: initialConfig.gatewayIP,
      guestIP: initialConfig.guestIP,
      guestMAC: configured.macAddress.string,
      dnsServers: initialConfig.dnsServers,
      caCertPEM: initialConfig.caCertPEM,
      caKeyPEM: initialConfig.caKeyPEM
    )
    try netstackSupervisor.configure(config: netstackConfig)
    let caCertPEM = netstackSupervisor.caCertPEM
    let caDescription = caCertPEM.isEmpty ? "none" : "\(caCertPEM.count) bytes"
    DVMLog.log(
      phase: .configuring,
      "dvm-netstack sidecar ready (CA: \(caDescription), guest_mac=\(configured.macAddress.string))"
    )
    netstackSupervisor.startMonitoring()
    tprint("Credential proxy started.")
    logNetworkConfiguration(configured: configured, netstackSupervisor: netstackSupervisor)
    return caCertPEM
  }

  fileprivate func logNetworkConfiguration(
    configured: ConfiguredVM,
    netstackSupervisor: NetstackSupervisor
  ) {
    let primaryTransport = netstackSupervisor.vmFD >= 0 ? "netstack" : "nat"
    let nfsTransport =
      configured.nfsMACAddress.map { ", nfs(mac=\($0.string), transport=nat)" } ?? ""
    DVMLog.log(
      phase: .configuring,
      "VM NICs: primary(mac=\(configured.macAddress.string), transport=\(primaryTransport))"
        + nfsTransport
    )
  }

  fileprivate func installSignalHandlers(
    controlSocket: ControlSocket,
    runner: VMRunner
  ) -> SignalSources {
    controlSocket.update(.booting)
    DVMLog.log(phase: .booting, "starting VM")
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let handleStop = makeStopHandler(controlSocket: controlSocket, runner: runner)
    sigintSource.setEventHandler(handler: handleStop)
    sigtermSource.setEventHandler(handler: handleStop)
    sigintSource.resume()
    sigtermSource.resume()
    return SignalSources(sigintSource: sigintSource, sigtermSource: sigtermSource)
  }

  fileprivate func makeStopHandler(
    controlSocket: ControlSocket,
    runner: VMRunner
  ) -> @Sendable () -> Void {
    {
      stopRequested = true
      controlSocket.update(.stopping)
      DVMLog.log(phase: .stopping, "stop signal received")
      Task { @MainActor in
        tprint("Stopping VM...")
        try? await runner.stop()
      }
    }
  }

  fileprivate func startGuestServices(
    runner: VMRunner,
    controlSocket: ControlSocket
  ) throws -> StartedGuestServices {
    let vsockBridge = try VsockDaemonBridge(virtualMachine: runner.virtualMachine)
    vsockBridge.start()
    let agentProxy = try AgentProxy(virtualMachine: runner.virtualMachine)
    agentProxy.start()
    let hostCommandBridgeBox = HostCommandBridgeBox()
    try startInitialHostCommandBridge(runner: runner, hostCommandBridgeBox: hostCommandBridgeBox)
    registerCapabilitiesReloadHandler(
      controlSocket: controlSocket,
      runner: runner,
      hostCommandBridgeBox: hostCommandBridgeBox
    )
    return StartedGuestServices(
      vsockBridge: vsockBridge,
      agentProxy: agentProxy,
      agentClient: AgentClient(),
      hostCommandBridgeBox: hostCommandBridgeBox
    )
  }

  fileprivate func startInitialHostCommandBridge(
    runner: VMRunner,
    hostCommandBridgeBox: HostCommandBridgeBox
  ) throws {
    guard let capPath = capabilities else { return }
    let manifest = try CapabilitiesManifest.load(from: capPath)
    guard !manifest.handlers.isEmpty else { return }
    let bridge = try HostCommandBridge(
      virtualMachine: runner.virtualMachine,
      manifest: manifest
    )
    bridge.start()
    hostCommandBridgeBox.bridge = bridge
  }

  fileprivate func registerCapabilitiesReloadHandler(
    controlSocket: ControlSocket,
    runner: VMRunner,
    hostCommandBridgeBox: HostCommandBridgeBox
  ) {
    controlSocket.reloadCapabilitiesHandler = { [weak runner] path in
      final class Box: @unchecked Sendable { var result: String? }
      let box = Box()
      let semaphore = DispatchSemaphore(value: 0)
      Task { @MainActor in
        defer { semaphore.signal() }
        do {
          let manifest = try CapabilitiesManifest.load(from: path)
          try reloadHostCommandBridge(
            manifest: manifest,
            path: path,
            runner: runner,
            hostCommandBridgeBox: hostCommandBridgeBox
          )
        } catch {
          box.result = "\(error)"
        }
      }
      return semaphore.wait(timeout: .now() + 5) == .success ? box.result : "reload timed out"
    }
  }

  @MainActor
  fileprivate func reloadHostCommandBridge(
    manifest: CapabilitiesManifest,
    path: String,
    runner: VMRunner?,
    hostCommandBridgeBox: HostCommandBridgeBox
  ) throws {
    if let bridge = hostCommandBridgeBox.bridge {
      try bridge.reload(from: path)
      return
    }
    guard !manifest.handlers.isEmpty, let virtualMachine = runner?.virtualMachine else { return }
    let bridge = try HostCommandBridge(
      virtualMachine: virtualMachine,
      manifest: manifest
    )
    bridge.start()
    hostCommandBridgeBox.bridge = bridge
  }

  fileprivate func startRuntime(
    prepared: PreparedStartContext,
    configured: ConfiguredStartContext
  ) async throws -> RunningStartContext {
    let signalSources = installSignalHandlers(
      controlSocket: prepared.controlSocket,
      runner: configured.runner
    )
    tprint("Starting VM...")
    try await configured.runner.start()
    let services = try startGuestServices(
      runner: configured.runner,
      controlSocket: prepared.controlSocket
    )
    let bootErrorMonitor = BootErrorMonitor(stateDir: prepared.stateDir)
    try await waitForActivationIfNeeded(
      stateDir: prepared.stateDir,
      runner: configured.runner,
      bootErrorMonitor: bootErrorMonitor,
      controlSocket: prepared.controlSocket
    )
    try await waitForGuestAgent(
      services: services,
      runner: configured.runner,
      controlSocket: prepared.controlSocket,
      bootErrorMonitor: bootErrorMonitor
    )
    let guestIP = try await resolveGuestIP(
      services: services,
      runner: configured.runner,
      controlSocket: prepared.controlSocket
    )
    let nfsExportManager = try await mountRuntimeShares(
      services: services,
      controlSocket: prepared.controlSocket,
      effectiveMounts: configured.effectiveMounts,
      nfsMACAddress: configured.nfsMACAddress,
      guestIP: guestIP
    )
    return RunningStartContext(
      signalSources: signalSources,
      services: services,
      guestIP: guestIP,
      nfsExportManager: nfsExportManager
    )
  }

  fileprivate func waitForActivationIfNeeded(
    stateDir: URL,
    runner: VMRunner,
    bootErrorMonitor: BootErrorMonitor,
    controlSocket: ControlSocket
  ) async throws {
    guard systemClosure != nil else { return }
    controlSocket.update(.activating)
    DVMLog.log(phase: .activating, "waiting for guest activation via state files")
    tprint("Waiting for guest activation...")

    let runDir = stateDir.appendingPathComponent(DVMLog.runId)
    let statusFile = runDir.appendingPathComponent("status")
    let logFile = stateDir.appendingPathComponent("run.log")
    let deadline = Date().addingTimeInterval(300)
    var logOffset = 0
    var logLineBuffer = ""
    var activatorStarted = false

    while Date() < deadline && !stopRequested {
      try await checkActivationBootError(bootErrorMonitor: bootErrorMonitor, runner: runner)
      drainActivationLog(logFile: logFile, logOffset: &logOffset, logLineBuffer: &logLineBuffer)
      let result = processActivationStatus(
        statusFile: statusFile,
        runDir: runDir,
        logLineBuffer: &logLineBuffer,
        activatorStarted: &activatorStarted
      )
      if result != .pending { return }
      try? await Task.sleep(nanoseconds: 500_000_000)
    }

    if !stopRequested && Date() >= deadline {
      DVMLog.log(phase: .activating, level: "error", "activation timed out after 5 min")
      tprint("Warning: activation did not complete within 5 minutes.")
    }
  }

  fileprivate func checkActivationBootError(
    bootErrorMonitor: BootErrorMonitor,
    runner: VMRunner
  ) async throws {
    guard let bootError = bootErrorMonitor.currentError() else { return }
    DVMLog.log(phase: .activating, level: "error", "guest boot failed: \(bootError)")
    tprint("FATAL: Guest boot failed: \(bootError)")
    try? await runner.stop()
    throw DVMError.activationFailed("guest boot failed: \(bootError)")
  }

  fileprivate func drainActivationLog(
    logFile: URL,
    logOffset: inout Int,
    logLineBuffer: inout String
  ) {
    guard let data = try? Data(contentsOf: logFile), data.count > logOffset else { return }
    let newData = data.subdata(in: logOffset..<data.count)
    logOffset = data.count
    guard let text = String(data: newData, encoding: .utf8) else { return }
    logLineBuffer += text
    var lines = logLineBuffer.components(separatedBy: "\n")
    logLineBuffer = lines.removeLast()
    for line in lines where !line.isEmpty {
      tprint(line)
    }
  }

  fileprivate func processActivationStatus(
    statusFile: URL,
    runDir: URL,
    logLineBuffer: inout String,
    activatorStarted: inout Bool
  ) -> ActivationPollResult {
    guard
      let statusText = try? String(contentsOf: statusFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return .pending }
    if statusText == "running" && !activatorStarted {
      activatorStarted = true
      DVMLog.log(phase: .activating, "activator running")
    }
    if statusText == "done" {
      flushActivationLogBuffer(&logLineBuffer)
      DVMLog.log(phase: .activating, "activation succeeded")
      tprint("Activation succeeded.")
      return .succeeded
    }
    guard statusText == "failed" || statusText == "invalid-closure" else { return .pending }
    flushActivationLogBuffer(&logLineBuffer)
    let exitCode = activationExitCode(runDir: runDir)
    DVMLog.log(
      phase: .activating,
      level: "error",
      "activation failed (status=\(statusText), exit=\(exitCode))"
    )
    tprint("Activation failed (exit code \(exitCode)).")
    return .failed
  }

  fileprivate func flushActivationLogBuffer(_ logLineBuffer: inout String) {
    guard !logLineBuffer.isEmpty else { return }
    tprint(logLineBuffer)
    logLineBuffer = ""
  }

  fileprivate func activationExitCode(runDir: URL) -> String {
    (try? String(
      contentsOf: runDir.appendingPathComponent("exit-code"),
      encoding: .utf8
    ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
  }

  fileprivate func waitForGuestAgent(
    services: StartedGuestServices,
    runner: VMRunner,
    controlSocket: ControlSocket,
    bootErrorMonitor: BootErrorMonitor
  ) async throws {
    controlSocket.update(.waitingForAgent)
    DVMLog.log(phase: .waitingForAgent, "waiting for guest agent")
    tprint("Waiting for guest agent...")

    guard await pollForGuestAgent(services: services, bootErrorMonitor: bootErrorMonitor) else {
      if stopRequested { return }
      controlSocket.update(.failed, error: "guest agent unreachable")
      tprint("Stopping VM.")
      try? await runner.stop()
      controlSocket.cleanup()
      services.agentProxy.cleanup()
      throw DVMError.activationFailed("guest agent unreachable")
    }

    DVMLog.log(phase: .waitingForAgent, "agent is reachable")
    tprint("Guest agent connected.")
    await logGuestNetworkSnapshot(agentClient: services.agentClient)
  }

  fileprivate func pollForGuestAgent(
    services: StartedGuestServices,
    bootErrorMonitor: BootErrorMonitor
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline && !stopRequested {
      if let bootError = bootErrorMonitor.currentError() {
        DVMLog.log(phase: .waitingForAgent, level: "error", "guest boot failed: \(bootError)")
        tprint("FATAL: Guest boot failed: \(bootError)")
        return false
      }
      if (try? await services.agentClient.status()) != nil {
        return true
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return false
  }

  fileprivate func logGuestNetworkSnapshot(agentClient: AgentClient) async {
    if let networkSnapshot = try? await agentClient.execCaptureOutput(
      command: ["sh", "-c", "ifconfig -a; printf '\\n--- ROUTES ---\\n'; netstat -rn -f inet"]
    ), !networkSnapshot.isEmpty {
      DVMLog.log(phase: .waitingForAgent, "guest network snapshot:\n\(networkSnapshot)")
      return
    }
    DVMLog.log(
      phase: .waitingForAgent,
      level: "warn",
      "failed to capture guest network snapshot"
    )
  }

  fileprivate func resolveGuestIP(
    services: StartedGuestServices,
    runner: VMRunner,
    controlSocket: ControlSocket
  ) async throws -> GuestIP {
    do {
      let guestIP = try await services.agentClient.resolveIP()
      tprint("VM reachable at \(guestIP)")
      DVMLog.log(phase: .waitingForAgent, "guest IP: \(guestIP)")
      return guestIP
    } catch {
      return try await resolveFallbackGuestIP(error: error, runner: runner, controlSocket: controlSocket)
    }
  }

  fileprivate func resolveFallbackGuestIP(
    error: Error,
    runner: VMRunner,
    controlSocket: ControlSocket
  ) async throws -> GuestIP {
    if let dhcpIP = runner.resolveIP() {
      tprint("VM reachable at \(dhcpIP) (DHCP fallback)")
      return dhcpIP
    }
    let message = "Could not resolve guest IP: \(error)"
    controlSocket.update(.failed, error: message)
    DVMLog.log(phase: .failed, level: "error", message)
    tprint("Warning: \(message)")
    tprint("VM running. Press Ctrl-C to stop.")
    await runner.waitUntilStopped()
    controlSocket.cleanup()
    tprint("VM stopped.")
    throw DVMError.activationFailed(message)
  }

  fileprivate func mountRuntimeShares(
    services: StartedGuestServices,
    controlSocket: ControlSocket,
    effectiveMounts: [MountConfig],
    nfsMACAddress: VZMACAddress?,
    guestIP: GuestIP
  ) async throws -> NFSExportManager? {
    let remainingMounts = effectiveMounts.filter { !["nix-store", "dvm-home"].contains($0.tag.rawValue) }
    controlSocket.update(.mounting, guestIP: guestIP)
    let preparation = try await prepareRuntimeMounts(
      remainingMounts: remainingMounts,
      nfsMACAddress: nfsMACAddress
    )
    DVMLog.log(
      phase: .mounting,
      "mounting \(remainingMounts.count) runtime shares (nix-store handled by image)"
    )
    tprint("Mounting runtime shares...")

    let scriptBody = try makeRuntimeMountScript(
      remainingMounts: remainingMounts,
      nfsHostIP: preparation.nfsHostIP
    )
    let mountExitCode = try await services.agentClient.exec(command: ["sudo", "sh", "-c", scriptBody])
    try await logRuntimeMountDiagnostics(
      agentClient: services.agentClient,
      hasNFSMirrorMounts: !preparation.nfsMirrorMounts.isEmpty
    )
    if mountExitCode != 0 {
      DVMLog.log(phase: .mounting, level: "error", "one or more runtime mounts failed")
      tprint("ERROR: One or more runtime mounts failed.")
    } else {
      DVMLog.log(phase: .mounting, "all mounts succeeded")
    }
    return preparation.nfsExportManager
  }

  fileprivate func prepareRuntimeMounts(
    remainingMounts: [MountConfig],
    nfsMACAddress: VZMACAddress?
  ) async throws -> RuntimeMountPreparation {
    let nfsMirrorMounts = remainingMounts.filter { $0.transport == .nfs && $0.isMirror }
    guard !nfsMirrorMounts.isEmpty else {
      return RuntimeMountPreparation(nfsMirrorMounts: [], nfsHostIP: nil, nfsExportManager: nil)
    }
    guard let nfsMACAddress else {
      fatalError("NFS mirror mounts exist but no NFS network MAC was configured")
    }
    DVMLog.log(phase: .mounting, "waiting for NFS NIC DHCP lease (mac=\(nfsMACAddress.string))")
    let nfsGuestIP = try await waitForNFSGuestIP(macAddress: nfsMACAddress)
    let hostResolution = try HostNetworkResolver.resolve(reachableFrom: nfsGuestIP)
    let manager = NFSExportManager(guestIP: nfsGuestIP)
    try manager.install(for: nfsMirrorMounts)
    DVMLog.log(
      phase: .mounting,
      "configuring NFS exports for \(nfsMirrorMounts.count) mirror mounts "
        + "(guest=\(nfsGuestIP), host=\(hostResolution.hostIP), mac=\(nfsMACAddress.string), \(hostResolution))"
    )
    return RuntimeMountPreparation(
      nfsMirrorMounts: nfsMirrorMounts,
      nfsHostIP: hostResolution.hostIP,
      nfsExportManager: manager
    )
  }

  fileprivate func waitForNFSGuestIP(macAddress: VZMACAddress) async throws -> GuestIP {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if let leaseIP = DHCPLeaseParser.getIPAddress(forMAC: macAddress.string) {
        return leaseIP
      }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    throw DVMError.activationFailed(
      "timed out waiting for NFS NIC DHCP lease for MAC \(macAddress.string)"
    )
  }

  fileprivate func makeRuntimeMountScript(
    remainingMounts: [MountConfig],
    nfsHostIP: GuestIP?
  ) throws -> String {
    let dvmMountsDir = "/var/dvm-mounts"
    let manifestPath = shellQuote(dvmMountsDir + "/.manifest")
    let mountLogDir = shellQuote("/tmp/dvm-mount-logs")
    var scriptParts: [String] = [
      "mkdir -p \(shellQuote(dvmMountsDir))",
      "> \(manifestPath)",
      "rm -rf \(mountLogDir)",
      "mkdir -p \(mountLogDir)",
      "PIDS=\"\""
    ]
    for mount in remainingMounts {
      let snippet = try runtimeMountSnippet(
        mount: mount,
        dvmMountsDir: dvmMountsDir,
        manifestPath: manifestPath,
        nfsHostIP: nfsHostIP
      )
      scriptParts.append(snippet.functionBody)
      scriptParts.append(snippet.callLine)
    }
    scriptParts += ["FAIL=0", "for pid in $PIDS; do wait $pid || FAIL=1; done", "exit $FAIL"]
    return scriptParts.joined(separator: "\n")
  }

  fileprivate func runtimeMountSnippet(
    mount: MountConfig,
    dvmMountsDir: String,
    manifestPath: String,
    nfsHostIP: GuestIP?
  ) throws -> (functionBody: String, callLine: String) {
    let mountPathRaw = runtimeMountPath(for: mount, dvmMountsDir: dvmMountsDir)
    let setupLines = runtimeMountSetupLines(mount: mount, mountPathRaw: mountPathRaw)
    let functionName = "mount_\(mount.tag.rawValue.replacingOccurrences(of: "-", with: "_"))"
    let functionBody = try makeRuntimeMountFunction(
      mount: mount,
      mountPathRaw: mountPathRaw,
      manifestPath: manifestPath,
      nfsHostIP: nfsHostIP,
      functionName: functionName
    )
    return (setupLines + "\n" + functionBody, "\(functionName) & PIDS=\"$PIDS $!\"")
  }

  fileprivate func runtimeMountPath(for mount: MountConfig, dvmMountsDir: String) -> String {
    mount.guestPath.rawValue.hasPrefix(guestHome + "/")
      ? "\(dvmMountsDir)/\(mount.tag.rawValue)"
      : mount.guestPath.rawValue
  }

  fileprivate func runtimeMountSetupLines(mount: MountConfig, mountPathRaw: String) -> String {
    let guestPath = mount.guestPath.rawValue
    guard guestPath.hasPrefix(guestHome + "/") else {
      let quotedPath = shellQuote(guestPath)
      return "[ -L \(quotedPath) ] && rm -f \(quotedPath); mkdir -p \(quotedPath)"
    }
    let mountPath = shellQuote(mountPathRaw)
    let quotedPath = shellQuote(guestPath)
    let parentDir = shellQuote((guestPath as NSString).deletingLastPathComponent)
    return [
      "mkdir -p \(mountPath)",
      "mkdir -p \(parentDir)",
      """
      if [ -L \(quotedPath) ]; then ln -sfn \(mountPath) \(quotedPath); \
      elif [ -d \(quotedPath) ]; then \
        if [ -z \"$(ls -A \(quotedPath) 2>/dev/null)\" ]; then \
          rmdir \(quotedPath) && ln -sfn \(mountPath) \(quotedPath); \
        else echo \"WARNING: \(quotedPath) is a non-empty directory, expected symlink.\" >&2; \
          echo \"Remove it manually: rm -rf \(quotedPath)\" >&2; fi; \
      else ln -sfn \(mountPath) \(quotedPath); fi
      """
    ].joined(separator: "\n")
  }

  fileprivate func makeRuntimeMountFunction(
    mount: MountConfig,
    mountPathRaw: String,
    manifestPath: String,
    nfsHostIP: GuestIP?,
    functionName: String
  ) throws -> String {
    let mountPath = shellQuote(mountPathRaw)
    let privateMountPathRaw =
      mountPathRaw.hasPrefix("/private/") ? mountPathRaw : "/private" + mountPathRaw
    let quotedTag = shellQuote(mount.tag.rawValue)
    let transport = shellQuote(mount.transport.rawValue)
    let writeManifest =
      "printf '%s %s %s\\n' \(transport) \(quotedTag) \(mountPath) >> \(manifestPath)"
    let tagLogPath = shellQuote("/tmp/dvm-mount-logs/\(mount.tag.rawValue).log")
    let displayPrefix = shellQuote(
      "[\(mount.tag.rawValue)] \(mount.hostPath.rawValue) -> \(mount.guestPath.rawValue) (\(mount.transport.rawValue))"
    )
    let mountDetails = try runtimeMountDetails(mount: mount, mountPath: mountPath, nfsHostIP: nfsHostIP)
    let prelude = runtimeMountFunctionPrelude(
      functionName: functionName,
      tagLogPath: tagLogPath,
      mountPathRaw: mountPathRaw,
      privateMountPathRaw: privateMountPathRaw,
      mount: mount,
      command: mountDetails.command
    )
    let alreadyMounted = runtimeMountAlreadyMountedBlock(
      displayPrefix: displayPrefix,
      writeManifest: writeManifest
    )
    let retryLoop = runtimeMountRetryLoop(
      expectedFS: mountDetails.expectedFS,
      command: mountDetails.command,
      displayPrefix: displayPrefix,
      writeManifest: writeManifest,
      mount: mount
    )
    return [prelude, alreadyMounted, retryLoop, "}"].joined(separator: "\n")
  }

  fileprivate func runtimeMountFunctionPrelude(
    functionName: String,
    tagLogPath: String,
    mountPathRaw: String,
    privateMountPathRaw: String,
    mount: MountConfig,
    command: String
  ) -> String {
    """
    \(functionName)() {
      log_mount() { printf '%s\\n' "$1" >> \(tagLogPath); }
      current_mount_line() {
        /sbin/mount | grep " on \(mountPathRaw) " | tail -n 1 || \
        /sbin/mount | grep " on \(privateMountPathRaw) " | tail -n 1
      }
      wait_for_mount_line() {
        line=""
        for _ in 1 2 3 4 5; do
          line=$(current_mount_line)
          [ -n "$line" ] && { printf '%s' "$line"; return 0; }
          sleep 0.2
        done
        return 1
      }
      log_mount "[BEGIN] \
      tag=\(mount.tag.rawValue) \
      transport=\(mount.transport.rawValue) \
      guest=\(mount.guestPath.rawValue) \
      host=\(mount.hostPath.rawValue)"
      log_mount "[CMD] \(command)"
      LINE=$(current_mount_line)
    """
  }

  fileprivate func runtimeMountAlreadyMountedBlock(
    displayPrefix: String,
    writeManifest: String
  ) -> String {
    """
      if [ -n "$LINE" ]; then
        echo "  \(displayPrefix) (already mounted)"
        log_mount "[ALREADY] $LINE"
        \(writeManifest)
        return 0
      fi
    """
  }

  fileprivate func runtimeMountRetryLoop(
    expectedFS: String,
    command: String,
    displayPrefix: String,
    writeManifest: String,
    mount: MountConfig
  ) -> String {
    """
      for i in 1 2 3 4 5; do
        ERR=$(\(command) 2>&1) && {
          LINE=$(wait_for_mount_line || true)
          case "$LINE" in
            *"(\(expectedFS),"*|*"(\(expectedFS))"*|*"("AppleVirtIOFS","*|\
            *"("AppleVirtIOFS")"*|*"(virtio-fs,"*|*"(virtio-fs))"*)
              echo "  \(displayPrefix)"
              log_mount "[OK] $LINE"
              \(writeManifest)
              return 0
              ;;
            *)
              log_mount "[VERIFY-FAILED] expected=\(expectedFS) actual=$LINE"
              ERR="mounted but unexpected fs type: $LINE"
              ;;
          esac
        }
        log_mount "[RETRY $i] $ERR"
        case "$ERR" in *"Resource busy"*) echo "  \(displayPrefix)"; \(writeManifest); return 0;; esac
        sleep 1
      done
      log_mount "[FAILED] tag=\(mount.tag.rawValue) error=$ERR"
      echo "  \(displayPrefix) (FAILED: $ERR)" >&2; return 1
    """
  }

  fileprivate func runtimeMountDetails(
    mount: MountConfig,
    mountPath: String,
    nfsHostIP: GuestIP?
  ) throws -> (expectedFS: String, command: String) {
    switch mount.transport {
    case .virtiofs:
      return ("virtiofs", "/sbin/mount_virtiofs \(mount.tag) \(mountPath)")
    case .nfs:
      guard let nfsHostIP else {
        fatalError("NFS mount command requested without resolved NFS host IP")
      }
      let remote = shellQuote("\(nfsHostIP.rawValue):\(mount.hostPath.rawValue)")
      return ("nfs", "/sbin/mount_nfs -o actimeo=1 \(remote) \(mountPath)")
    }
  }

  fileprivate func logRuntimeMountDiagnostics(
    agentClient: AgentClient,
    hasNFSMirrorMounts: Bool
  ) async throws {
    if let mountLog = try await agentClient.execCaptureOutput(
      command: [
        "sudo", "sh", "-c",
        """
        for f in /tmp/dvm-mount-logs/*.log; do [ -f "$f" ] || continue; \
        echo "=== $(basename "$f") ==="; cat "$f"; echo; done
        """
      ]
    ), !mountLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      DVMLog.log(phase: .mounting, "guest mount transcript:\n\(mountLog)")
    } else {
      DVMLog.log(phase: .mounting, level: "warn", "guest mount transcript missing or empty")
    }

    if let manifest = try await agentClient.execCaptureOutput(command: ["cat", "/var/dvm-mounts/.manifest"]),
      !manifest.isEmpty
    {
      DVMLog.log(phase: .mounting, "runtime mount manifest:\n\(manifest)")
    } else {
      DVMLog.log(phase: .mounting, level: "warn", "runtime mount manifest missing or unreadable")
    }

    guard hasNFSMirrorMounts else { return }
    if let nfsMountState = try await agentClient.execCaptureOutput(
      command: ["sh", "-c", "nfsstat -m 2>/dev/null || true"]
    ), !nfsMountState.isEmpty {
      DVMLog.log(phase: .mounting, "guest nfsstat -m:\n\(nfsMountState)")
    } else {
      DVMLog.log(phase: .mounting, level: "warn", "guest nfsstat -m empty or unavailable")
    }
  }

  fileprivate func restartGuestBridgeAndInstallCA(
    agentClient: AgentClient,
    caCertPEM: String
  ) async throws {
    tprint("Restarting nix daemon bridge...")
    _ = try await agentClient.exec(command: ["sudo", "launchctl", "bootout", "system/com.darvm.agent-bridge"])
    _ = try await agentClient.exec(
      command: [
        "sudo", "launchctl", "bootstrap", "system",
        "/Library/LaunchDaemons/com.darvm.agent-bridge.plist"
      ]
    )
    try await installGuestCA(agentClient: agentClient, caCertPEM: caCertPEM)
  }

  fileprivate func installGuestCA(
    agentClient: AgentClient,
    caCertPEM: String
  ) async throws {
    guard !caCertPEM.isEmpty else { return }
    let certScript = """
      printf '%s' \(shellQuote(caCertPEM)) > /tmp/dvm-ca.pem && \
      security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/dvm-ca.pem && \
      rm -f /tmp/dvm-ca.pem
      """
    let caInstallCode = try await agentClient.exec(command: ["sudo", "sh", "-c", certScript])
    if caInstallCode != 0 {
      DVMLog.log(level: "warn", "failed to install MITM CA in guest trust store")
      tprint("Warning: failed to install CA cert in guest. HTTPS interception may not work.")
    } else {
      DVMLog.log(phase: .activating, "installed MITM CA in guest trust store")
      tprint("MITM CA installed in guest trust store.")
    }
    let nodeCAScript = """
      printf '%s' \(shellQuote(caCertPEM)) > /etc/dvm-ca.pem && \
      chmod 644 /etc/dvm-ca.pem
      """
    _ = try await agentClient.exec(command: ["sudo", "sh", "-c", nodeCAScript])
    DVMLog.log(phase: .activating, "wrote CA cert to /etc/dvm-ca.pem for NODE_EXTRA_CA_CERTS")
  }

  fileprivate func registerRuntimeHandlers(
    controlSocket: ControlSocket,
    services: StartedGuestServices,
    netstackSupervisor: NetstackSupervisor
  ) {
    controlSocket.loadCredentialsHandler = { [netstackSupervisor] projectName, secretDicts in
      do {
        let secrets = try decodeResolvedSecrets(secretDicts)
        try netstackSupervisor.loadCredentials(projectName: projectName, secrets: secrets)
        return nil
      } catch {
        return "\(error)"
      }
    }
    controlSocket.guestHealthHandler = { [agentClient = services.agentClient] in
      final class Box: @unchecked Sendable { var value: GuestHealthPayload? }
      let box = Box()
      let semaphore = DispatchSemaphore(value: 0)
      Task {
        defer { semaphore.signal() }
        if let status = try? await agentClient.status() {
          box.value = GuestHealthPayload(
            mounts: status.mounts,
            activation: status.activation,
            services: status.services.reduce(into: [:]) { $0[$1.key] = $1.value }
          )
        }
      }
      guard semaphore.wait(timeout: .now() + 5) == .success else { return nil }
      return box.value
    }
  }

  fileprivate func decodeResolvedSecrets(_ secretDicts: [[String: Any]]) throws -> [ResolvedSecret] {
    try secretDicts.enumerated().map { index, dict in
      guard let name = dict["name"] as? String,
        let placeholder = dict["placeholder"] as? String,
        let value = dict["value"] as? String,
        let hosts = dict["hosts"] as? [String]
      else {
        throw DVMError.activationFailed(
          "loadCredentials: secret at index \(index) has missing or invalid fields"
        )
      }
      return ResolvedSecret(
        name: name,
        mode: .proxy,
        placeholder: placeholder,
        value: value,
        hosts: hosts
      )
    }
  }

  fileprivate func finishRunningSession(
    guestIP: GuestIP,
    controlSocket: ControlSocket,
    services: StartedGuestServices,
    netstackSupervisor: NetstackSupervisor,
    runner: VMRunner
  ) async {
    controlSocket.update(.running, guestIP: guestIP)
    DVMLog.log(phase: .running, "VM running at \(guestIP)")
    tprint("VM running. Press Ctrl-C to stop.")
    await runner.waitUntilStopped()
    controlSocket.update(.stopped)
    DVMLog.log(phase: .stopped, "VM stopped")
    DVMLog.log(phase: .stopped, "shutting down dvm-netstack")
    netstackSupervisor.shutdown()
    controlSocket.cleanup()
    services.agentProxy.cleanup()
    tprint("VM stopped.")
  }

  fileprivate func removeManagedExports(_ manager: NFSExportManager?) {
    do {
      try manager?.removeManagedExports()
    } catch {
      DVMLog.log(level: "error", "failed to remove DVM NFS exports: \(error)")
    }
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
  let explicit =
    credentialsFlag != nil
    || ProcessInfo.processInfo.environment["DVM_CREDENTIALS"] != nil

  guard
    let path = try discoverManifestPath(
      credentialsFlag: credentialsFlag, cwd: cwd)
  else {
    return [:]  // no manifest, no credentials — session runs without injection
  }

  do {
    let manifest = try CredentialManifest.load(from: path)
    let hostKey = try HostKey.loadOrCreate()
    let secrets = try manifest.resolve(hostKey: hostKey)

    // Only proxy secrets need MITM interception via the sidecar.
    let proxySecrets = secrets.filter { $0.mode == .proxy }

    // Always push — even empty secrets list clears previous mappings for this project.
    if let error = ControlSocket.sendLoadCredentials(
      projectName: manifest.project, secrets: proxySecrets)
    {
      throw CredentialPushError(detail: error)
    }

    // Build env vars for guest injection:
    // - proxy secrets: ENV_VAR=placeholder (sidecar substitutes real value)
    // - passthrough secrets: ENV_VAR=realValue (injected directly)
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
      if let ipAddress = payload.ipAddress { result["ip"] = ipAddress }
      if let runId = payload.runId { result["run_id"] = runId }
      if let phaseError = payload.phaseError { result["error"] = phaseError }

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
    let statusResult = ControlSocket.send(.status)
    switch statusResult {
    case .success(.status(let payload)):
      guard payload.running else { try printStoppedStatus(payload) }
      print(statusSummaryLine(payload))
      if let runId = payload.runId {
        print("  Run:        \(runId)")
      }

      if payload.phase == VMPhase.running.rawValue {
        printGuestHealthSummary()
      }
    default:
      try throwStatusFailure(statusResult)
    }
  }
}
