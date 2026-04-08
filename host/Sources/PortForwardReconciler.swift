import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

/// Polls the guest agent for loopback listeners and reconciles the host
/// port forwarder to match, subject to `PortPolicy` filtering.
///
/// New guest listeners are published immediately. Vanished listeners are
/// unpublished after 2 consecutive absent polls (hysteresis) to avoid
/// flapping during service restarts. Previously conflicted ports are
/// retried on each tick in case the conflict clears.
///
/// Uses a single persistent gRPC connection for the reconciler's lifetime
/// to avoid fd accumulation from per-call connection churn.
@MainActor
final class PortForwardReconciler {
  private let socketPath: String
  private let portForwarder: PortForwarder
  private let policy: PortPolicy
  private var reconcileTask: Task<Void, Never>?

  /// How many consecutive polls a port must be absent before unpublishing.
  private let unpublishThreshold = 2

  /// Poll interval between reconciliation ticks.
  private let pollInterval: Duration = .seconds(2)

  /// Consecutive absent-poll counts for currently published ports.
  private var missCount: [UInt16: Int] = [:]

  init(portForwarder: PortForwarder, policy: PortPolicy, socketPath: String = "/tmp/darvm-agent.sock") {
    self.socketPath = socketPath
    self.portForwarder = portForwarder
    self.policy = policy
  }

  func start() {
    guard reconcileTask == nil else {
      return
    }
    reconcileTask = Task { [weak self] in
      await self?.runLoop()
    }
  }

  func stop() async {
    reconcileTask?.cancel()
    reconcileTask = nil
    await portForwarder.stop()
  }

  private func runLoop() async {
    // Outer loop: maintain the persistent connection.
    // If the connection drops, we reconnect after a brief pause.
    while !Task.isCancelled {
      do {
        try await withPersistentClient { agent in
          while !Task.isCancelled {
            await self.reconcileOnce(agent: agent)
            try await Task.sleep(for: self.pollInterval)
          }
        }
      } catch is CancellationError {
        break
      } catch {
        DVMLog.log(level: "debug", "port forward reconciler: connection lost, reconnecting")
        try? await Task.sleep(for: pollInterval)
      }
    }
  }

  /// Establish a persistent gRPC connection and run the body until
  /// it returns or the connection fails. Only one connection is open
  /// at a time — no fd accumulation.
  private func withPersistentClient(
    _ body: @Sendable (Darvm_Agent.Client<HTTP2ClientTransport.Posix>) async throws -> Void
  ) async throws {
    let transport = try HTTP2ClientTransport.Posix(
      target: .unixDomainSocket(path: socketPath),
      transportSecurity: .plaintext
    )
    let client = GRPCClient(transport: transport)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await client.runConnections()
      }

      let agent = Darvm_Agent.Client(wrapping: client)
      do {
        try await body(agent)
      } catch {
        client.beginGracefulShutdown()
        group.cancelAll()
        throw error
      }
      client.beginGracefulShutdown()
    }
  }

  private func reconcileOnce(
    agent: Darvm_Agent.Client<HTTP2ClientTransport.Posix>
  ) async {
    guard let status = try? await agent.status(Darvm_StatusRequest()) else {
      return
    }

    let guestPorts: Set<UInt16> = Set(
      status.loopbackListeners.compactMap { rawValue in
        let port = UInt16(clamping: rawValue)
        guard port > 0, port == rawValue, policy.isAllowed(port) else {
          return nil
        }
        return port
      }
    )

    let currentlyPublished = portForwarder.publishedPorts

    // Publish new ports that appeared in the guest.
    // Exclude ports already in conflicts — those are retried separately below.
    let newPorts = guestPorts.subtracting(currentlyPublished).subtracting(portForwarder.conflicts)
    for port in newPorts.sorted() {
      await portForwarder.publish(port: port)
      missCount.removeValue(forKey: port)
    }

    // Reset miss count for ports still present.
    for port in currentlyPublished.intersection(guestPorts) {
      missCount.removeValue(forKey: port)
    }

    // Track misses for ports that vanished; unpublish after threshold.
    for port in currentlyPublished.subtracting(guestPorts) {
      let count = (missCount[port] ?? 0) + 1
      missCount[port] = count

      if count >= unpublishThreshold {
        await portForwarder.unpublish(port: port)
        missCount.removeValue(forKey: port)
      }
    }

    // Retry previously conflicted ports that are still in the guest set.
    // The conflict may have cleared (e.g. the host process released the port).
    let retriable = portForwarder.conflicts.intersection(guestPorts)
    for port in retriable.sorted() {
      await portForwarder.publish(port: port)
    }
  }
}
