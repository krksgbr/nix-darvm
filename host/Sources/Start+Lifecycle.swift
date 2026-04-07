import ArgumentParser
import Foundation
import Virtualization

@MainActor
extension Start {
  func configureLogging() {
    let effectiveDebug =
      debug || logPredicate != nil || ProcessInfo.processInfo.environment["DVM_DEBUG"] == "1"
    DVMLog.debugMode = effectiveDebug
    DVMLog.log(phase: .stopped, "dvm starting (run_id=\(DVMLog.runId), log=\(DVMLog.logPath))")
  }

  func prepareStartContext() throws -> PreparedStartContext {
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

  func buildConfiguredMounts() throws -> [MountConfig] {
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

  func prepareControlSocket() throws -> ControlSocket {
    guard !ControlSocket.isRunning() else {
      throw DVMError.alreadyRunning
    }
    let controlSocket = ControlSocket()
    try controlSocket.listen()
    return controlSocket
  }

  func currentVMDirectory() -> URL {
    let effectiveVMName = vmName ?? defaultVMName
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".tart/vms/\(effectiveVMName)")
  }

  func makeNetstackSupervisor(netstackBinary: String) throws -> NetstackSupervisor {
    try NetstackSupervisor.launch(
      config: initialNetstackConfig(netstackBinary: netstackBinary)
    ) {
      DVMLog.log(level: "error", "dvm-netstack crashed — networking is down, failing closed")
      tprint("FATAL: Credential proxy (dvm-netstack) crashed. VM networking is down.")
    }
  }

  func initialNetstackConfig(netstackBinary: String) -> NetstackSupervisor.Config {
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

  func makeStateDir() throws -> URL {
    let dvmLocalDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/state/dvm")
    let stateDir = URL(fileURLWithPath: dvmLocalDir.path)
    try? FileManager.default.removeItem(at: stateDir)
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    DVMLog.log(phase: .configuring, "state dir: \(stateDir.path)")
    return stateDir
  }

  func makeHomeDataDir(from stateDir: URL) throws -> URL {
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

  func writeActivationFilesIfNeeded(stateDir: URL) throws {
    guard let closure = systemClosure else {
      return
    }
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

  func configureRuntime(using prepared: PreparedStartContext) throws -> ConfiguredStartContext {
    let configured = try VMConfigurator.create(
      vmDir: prepared.vmDirectory,
      mounts: prepared.mounts,
      homeDataDir: prepared.homeDataDir,
      netstackFD: prepared.netstackSupervisor.vmFD,
      stateDir: prepared.stateDir
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

  func configureNetstack(
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

  func logNetworkConfiguration(
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

  func installSignalHandlers(
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

  func makeStopHandler(
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

  func startGuestServices(
    runner: VMRunner,
    controlSocket: ControlSocket
  ) async throws -> StartedGuestServices {
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
      hostCommandBridgeBox: hostCommandBridgeBox,
      portForwarder: nil
    )
  }

  func startHostPortForwarding(
    runner: VMRunner,
    forwardPorts: [UInt16]
  ) async throws -> PortForwarder? {
    guard !forwardPorts.isEmpty else {
      return nil
    }

    let mappings = forwardPorts.map {
      PortForwarder.PortMapping(hostPort: $0, guestPort: $0)
    }
    let forwarder = try PortForwarder(
      virtualMachine: runner.virtualMachine,
      mappings: mappings
    )

    do {
      try await forwarder.start()
    } catch {
      forwarder.stop()
      throw error
    }

    for port in forwardPorts {
      tprint("Port forwarding: localhost:\(port) → guest:\(port)")
    }

    return forwarder
  }

  func startInitialHostCommandBridge(
    runner: VMRunner,
    hostCommandBridgeBox: HostCommandBridgeBox
  ) throws {
    guard let capPath = capabilities else {
      return
    }
    let manifest = try CapabilitiesManifest.load(from: capPath)
    guard !manifest.handlers.isEmpty else {
      return
    }
    let bridge = try HostCommandBridge(
      virtualMachine: runner.virtualMachine,
      manifest: manifest
    )
    bridge.start()
    hostCommandBridgeBox.bridge = bridge
  }

  func registerCapabilitiesReloadHandler(
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
  func reloadHostCommandBridge(
    manifest: CapabilitiesManifest,
    path: String,
    runner: VMRunner?,
    hostCommandBridgeBox: HostCommandBridgeBox
  ) throws {
    if let bridge = hostCommandBridgeBox.bridge {
      try bridge.reload(from: path)
      return
    }
    guard !manifest.handlers.isEmpty,
      let virtualMachine = runner?.virtualMachine
    else {
      return
    }
    let bridge = try HostCommandBridge(
      virtualMachine: virtualMachine,
      manifest: manifest
    )
    bridge.start()
    hostCommandBridgeBox.bridge = bridge
  }

  func startRuntime(
    prepared: PreparedStartContext,
    configured: ConfiguredStartContext
  ) async throws -> RunningStartContext {
    let config = try DVMConfig.load()
    let signalSources = installSignalHandlers(
      controlSocket: prepared.controlSocket,
      runner: configured.runner
    )
    tprint("Starting VM...")
    try await configured.runner.start()
    var services = try await startGuestServices(
      runner: configured.runner,
      controlSocket: prepared.controlSocket
    )
    let bootErrorMonitor = BootErrorMonitor(stateDir: prepared.stateDir)

    do {
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
        bootErrorMonitor: bootErrorMonitor,
        stateDir: prepared.stateDir,
        requirePortForwardReady: !config.forwardPorts.isEmpty
      )

      services.portForwarder = try await startHostPortForwarding(
        runner: configured.runner,
        forwardPorts: config.forwardPorts
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
    } catch {
      await rollbackFailedStart(
        error: error,
        runner: configured.runner,
        controlSocket: prepared.controlSocket,
        services: services
      )
      throw error
    }
  }

  func rollbackFailedStart(
    error: Error,
    runner: VMRunner,
    controlSocket: ControlSocket,
    services: StartedGuestServices
  ) async {
    DVMLog.log(level: "error", "start failed after VM boot: \(error)")
    tprint("Stopping VM.")
    controlSocket.update(.failed, error: "\(error)")
    try? await runner.stop()
    controlSocket.cleanup()
    services.agentProxy.cleanup()
    services.portForwarder?.stop()
  }
}
