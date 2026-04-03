import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

extension AgentClient {
  fileprivate func withAgentClient<T: Sendable>(
    allowRetry: Bool = true,
    _ body: @Sendable (Darvm_Agent.Client<HTTP2ClientTransport.Posix>) async throws -> T
  ) async throws -> T {
    let maxAttempts = allowRetry ? 4 : 1
    var lastError: Error?

    for attempt in 1...maxAttempts {
      do {
        return try await withAgentClientOnce(body)
      } catch let error as RPCError where error.code == .unavailable {
        lastError = error
        guard attempt < maxAttempts else { break }
        DVMLog.log(
          level: "debug",
          "agent unavailable (attempt \(attempt)/\(maxAttempts)), retrying in 1s: \(error)"
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }

    throw lastError!
  }

  fileprivate func withAgentClientOnce<T: Sendable>(
    _ body: @Sendable (Darvm_Agent.Client<HTTP2ClientTransport.Posix>) async throws -> T
  ) async throws -> T {
    let transport = try HTTP2ClientTransport.Posix(
      target: .unixDomainSocket(path: socketPath),
      transportSecurity: .plaintext
    )
    let client = GRPCClient(transport: transport)

    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try? await client.runConnections()
        throw CancellationError()
      }

      let agent = Darvm_Agent.Client(wrapping: client)
      let result = try await body(agent)
      client.beginGracefulShutdown()
      group.cancelAll()
      return result
    }
  }

  func waitForAgent(timeout: TimeInterval = 60) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    var lastError: Error?
    var attempts = 0

    while Date() < deadline {
      attempts += 1
      do {
        _ = try await status()
        DVMLog.log(level: "info", "agent reachable after \(attempts) attempt(s)")
        return
      } catch {
        let errStr = "\(error)"
        if lastError == nil || "\(lastError!)" != errStr {
          DVMLog.log(level: "debug", "waitForAgent attempt \(attempts): \(errStr)")
        }
        lastError = error
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }

    throw AgentClientError.agentTimeout(lastError)
  }
}
