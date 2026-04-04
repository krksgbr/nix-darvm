import ArgumentParser
import Foundation

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
