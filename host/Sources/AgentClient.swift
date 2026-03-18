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
        guard let ip = GuestIP(response.ip) else {
            throw AgentClientError.invalidIP(response.ip)
        }
        return ip
    }

    /// Activate a nix-darwin system closure in the guest.
    func activate(closurePath: String, updateProfile: Bool = false) async throws -> Darvm_ActivateResponse {
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
    func exec(command: [String], cwd: String? = nil, env: [String: String] = [:]) async throws -> Int32 {
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
                        var ev = Darvm_EnvVar()
                        ev.name = key
                        ev.value = value
                        return ev
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

        return try await withAgentClient { agent in
            // Use a task group so we can cancel the request producer
            // when the response handler receives the exit code.
            try await withThrowingTaskGroup(of: Int32.self) { outerGroup in
                outerGroup.addTask {
                    try await agent.exec(
                        requestProducer: { writer in
                            var cmd = Darvm_Command()
                            cmd.name = cmdName
                            cmd.args = cmdArgs
                            cmd.interactive = true
                            cmd.tty = useTTY
                            if let workDir { cmd.workingDirectory = workDir }
                            cmd.environment = env.map { key, value in
                                var ev = Darvm_EnvVar()
                                ev.name = key
                                ev.value = value
                                return ev
                            }
                            if useTTY {
                                let (w, h) = try Term.getSize()
                                var size = Darvm_TerminalSize()
                                size.cols = UInt32(w)
                                size.rows = UInt32(h)
                                cmd.terminalSize = size
                            }

                            var req = Darvm_ExecRequest()
                            req.type = .command(cmd)
                            try await writer.write(req)

                            // Stream stdin and terminal resize events concurrently
                            try await withThrowingTaskGroup(of: Void.self) { group in
                                group.addTask {
                                    try await Self.streamStdin(to: writer)
                                }

                                if useTTY {
                                    group.addTask {
                                        try await Self.streamTerminalResizes(to: writer)
                                    }
                                }

                                try await group.next()
                                group.cancelAll()
                            }
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

                // Get the result and cancel everything else
                let exitCode = try await outerGroup.next() ?? 1
                outerGroup.cancelAll()
                return exitCode
            }
        }
    }

    // MARK: - Private

    private func withAgentClient<T: Sendable>(
        _ body: @Sendable (Darvm_Agent.Client<HTTP2ClientTransport.Posix>) async throws -> T
    ) async throws -> T {
        // We manage the client lifecycle manually instead of using withGRPCClient
        // because the graceful HTTP/2 shutdown can hang when the proxy doesn't
        // propagate GOAWAY cleanly. We call the RPC, get the result, then
        // force-close the transport.
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

            // Don't wait for graceful shutdown — cancel the connections task
            group.cancelAll()
            return result
        }
    }

    /// Execute a command and capture stdout as a string. Returns nil on non-zero exit.
    func execCaptureOutput(command: [String], cwd: String? = nil) async throws -> String? {
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

                    var req = Darvm_ExecRequest()
                    req.type = .command(cmd)
                    try await writer.write(req)
                },
                onResponse: { response in
                    switch response.accepted {
                    case .success(let contents):
                        var output = Data()
                        for try await part in contents.bodyParts {
                            switch part {
                            case .message(let msg):
                                switch msg.type {
                                case .standardOutput(let chunk):
                                    output.append(chunk.data)
                                case .exit(let exit):
                                    guard exit.code == 0 else { return nil }
                                    return String(data: output, encoding: .utf8)?
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                default:
                                    break
                                }
                            case .trailingMetadata:
                                break
                            }
                        }
                        return nil
                    case .failure:
                        return nil
                    }
                }
            )
        }
    }

    /// Wait for the guest agent to become reachable. Retries with backoff.
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
                // Only log when the error type changes to reduce noise
                if lastError == nil || "\(lastError!)" != errStr {
                    DVMLog.log(level: "debug", "waitForAgent attempt \(attempts): \(errStr)")
                }
                lastError = error
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            }
        }

        throw AgentClientError.agentTimeout(lastError)
    }

    // MARK: - Exec stream helpers

    /// Process the response stream from an Exec RPC. Returns exit code.
    private static func processExecStream(
        _ bodyParts: RPCAsyncSequence<StreamingClientResponse<Darvm_ExecResponse>.Contents.BodyPart, any Error>
    ) async throws -> Int32 {
        for try await part in bodyParts {
            switch part {
            case .message(let response):
                switch response.type {
                case .standardOutput(let chunk):
                    try FileHandle.standardOutput.write(contentsOf: chunk.data)
                case .standardError(let chunk):
                    try FileHandle.standardError.write(contentsOf: chunk.data)
                case .exit(let exit):
                    return exit.code
                case nil:
                    break
                }
            case .trailingMetadata:
                break
            }
        }
        return 1  // Stream ended without exit message
    }

    /// Stream stdin to the gRPC writer until EOF or cancellation.
    /// Uses DispatchSource for non-blocking reads that respect task cancellation.
    private static func streamStdin(to writer: RPCWriter<Darvm_ExecRequest>) async throws {
        let fd = FileHandle.standardInput.fileDescriptor
        let stream = AsyncStream<Data> { continuation in
            let source = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: DispatchQueue.global(qos: .userInteractive)
            )
            source.setEventHandler {
                let available = source.data // estimated bytes available
                guard available > 0 else { return }
                var buf = [UInt8](repeating: 0, count: Int(available))
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    continuation.yield(Data(buf[..<n]))
                } else {
                    continuation.finish()
                }
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }

        for await data in stream {
            try Task.checkCancellation()
            var chunk = Darvm_IOChunk()
            chunk.data = data
            var req = Darvm_ExecRequest()
            req.type = .standardInput(chunk)
            try await writer.write(req)
        }

        // EOF — signal closure
        var req = Darvm_ExecRequest()
        req.type = .standardInput(Darvm_IOChunk())
        try await writer.write(req)
    }

    /// Stream terminal resize events (SIGWINCH) to the gRPC writer.
    private static func streamTerminalResizes(to writer: RPCWriter<Darvm_ExecRequest>) async throws {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.resume()
        defer { source.cancel() }

        let stream = AsyncStream<Void> { continuation in
            source.setEventHandler { continuation.yield() }
            continuation.onTermination = { _ in source.cancel() }
        }

        for await _ in stream {
            guard let (w, h) = try? Term.getSize() else { continue }
            var size = Darvm_TerminalSize()
            size.cols = UInt32(w)
            size.rows = UInt32(h)
            var req = Darvm_ExecRequest()
            req.type = .terminalResize(size)
            try await writer.write(req)
        }
    }
}

enum AgentClientError: Error, CustomStringConvertible {
    case invalidIP(String)
    case agentTimeout(Error?)

    var description: String {
        switch self {
        case .invalidIP(let ip): return "Agent returned invalid IP: \(ip)"
        case .agentTimeout(let err):
            if let err { return "Agent not reachable after timeout: \(err)" }
            return "Agent not reachable after timeout"
        }
    }
}
