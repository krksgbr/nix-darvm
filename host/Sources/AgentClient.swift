import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

/// High-level wrapper around the gRPC Agent service client.
///
/// Connects to the guest agent via the AgentProxy's Unix domain socket.
/// All methods are async and throw on failure.
struct AgentClient: Sendable {
  let socketPath: String

  init(socketPath: String = "/tmp/darvm-agent.sock") {
    self.socketPath = socketPath
  }

  // MARK: - Unary RPCs

  /// Resolve the guest VM's IP address.
  func resolveIP() async throws -> GuestIP {
    let response = try await withAgentClient { agent in
      try await agent.resolveIP(Darvm_ResolveIPRequest())
    }
    guard let guestIP = GuestIP(response.ip) else {
      throw AgentClientError.invalidIP(response.ip)
    }
    return guestIP
  }

  /// Activate a nix-darwin system closure in the guest.
  func activate(closurePath: String, updateProfile: Bool = false) async throws
    -> Darvm_ActivateResponse
  {
    var req = Darvm_ActivateRequest()
    req.closurePath = closurePath
    req.updateProfile = updateProfile
    let message = req
    return try await withAgentClient { agent in
      try await agent.activate(message)
    }
  }

  /// Query guest health status.
  func status() async throws -> Darvm_StatusResponse {
    try await withAgentClient { agent in
      try await agent.status(Darvm_StatusRequest())
    }
  }

  // MARK: - Exec (bidirectional streaming)

  /// Execute a non-interactive command and return the exit code.
  /// Stdout/stderr are written to the caller's stdout/stderr.
  /// When `env` is provided, those vars are injected into the child process environment.
  func exec(command: [String], cwd: String? = nil, env: [String: String] = [:]) async throws
    -> Int32
  {
    let cmdName = command[0]
    let cmdArgs = Array(command.dropFirst())
    let workDir = cwd

    return try await withAgentClient { agent in
      try await agent.exec(
        requestProducer: { writer in
          var cmd = Darvm_Command()
          cmd.name = cmdName
          cmd.args = cmdArgs
          cmd.interactive = false
          cmd.tty = false
          if let workDir { cmd.workingDirectory = workDir }
          cmd.environment = env.map { key, value in
            var envVar = Darvm_EnvVar()
            envVar.name = key
            envVar.value = value
            return envVar
          }

          var req = Darvm_ExecRequest()
          req.type = .command(cmd)
          try await writer.write(req)
        },
        onResponse: { response in
          switch response.accepted {
          case .success(let contents):
            return try await Self.processExecStream(contents.bodyParts)
          case .failure(let error):
            throw error
          }
        }
      )
    }
  }

  /// Execute a command with full TTY + interactive stdin support.
  /// Used for `dvm ssh` and `dvm exec -t`.
  func execInteractive(
    command: [String],
    cwd: String? = nil,
    tty: Bool = true,
    env: [String: String] = [:]
  ) async throws -> Int32 {
    var termState: TermState?
    if tty && Term.isTerminal() {
      termState = try Term.makeRaw()
    }
    defer {
      if let termState { Term.restore(termState) }
    }

    let cmdName = command[0]
    let cmdArgs = Array(command.dropFirst())
    let workDir = cwd
    let useTTY = tty

    // allowRetry: true — .unavailable here means the agent closed the
    // connection before the HTTP/2 preface, i.e. before any exec request
    // was sent. Retrying is safe. If the agent crashes mid-exec we'd also
    // get .unavailable, but the defer above already restored the terminal,
    // so starting a new session on retry is the right behaviour.
    return try await withAgentClient(allowRetry: true) { agent in
      // Use a task group so we can cancel the request producer
      // when the response handler receives the exit code.
      let commandRequest = try Self.makeInteractiveCommand(
        name: cmdName,
        args: cmdArgs,
        workingDirectory: workDir,
        tty: useTTY,
        env: env
      )
      try await withThrowingTaskGroup(of: Int32.self) { outerGroup in
        outerGroup.addTask {
          try await agent.exec(
            requestProducer: { writer in
              try await Self.runInteractiveRequestProducer(
                writer: writer,
                commandRequest: commandRequest,
                tty: useTTY
              )
            },
            onResponse: Self.processExecResponse
          )
        }

        // Get the result and cancel everything else
        let exitCode = try await outerGroup.next() ?? 1
        outerGroup.cancelAll()
        return exitCode
      }
    }
  }

}

enum AgentClientError: Error, CustomStringConvertible {
  case invalidIP(String)
  case agentTimeout(Error?)

  var description: String {
    switch self {
    case .invalidIP(let ipAddress): return "Agent returned invalid IP: \(ipAddress)"
    case .agentTimeout(let error):
      if let error { return "Agent not reachable after timeout: \(error)" }
      return "Agent not reachable after timeout"
    }
  }
}
