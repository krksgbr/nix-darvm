import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

extension AgentClient {
  static func makeInteractiveCommand(
    name: String,
    args: [String],
    workingDirectory: String?,
    tty: Bool,
    env: [String: String]
  ) throws -> Darvm_Command {
    var command = Darvm_Command()
    command.name = name
    command.args = args
    command.interactive = true
    command.tty = tty
    if let workingDirectory { command.workingDirectory = workingDirectory }
    command.environment = env.map { key, value in
      var envVar = Darvm_EnvVar()
      envVar.name = key
      envVar.value = value
      return envVar
    }
    if tty {
      let (width, height) = try Term.getSize()
      var size = Darvm_TerminalSize()
      size.cols = UInt32(width)
      size.rows = UInt32(height)
      command.terminalSize = size
    }
    return command
  }

  static func runInteractiveRequestProducer(
    writer: RPCWriter<Darvm_ExecRequest>,
    commandRequest: Darvm_Command,
    tty: Bool
  ) async throws {
    var request = Darvm_ExecRequest()
    request.type = .command(commandRequest)
    try await writer.write(request)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await Self.streamStdin(to: writer)
      }

      if tty {
        group.addTask {
          try await Self.streamTerminalResizes(to: writer)
        }
      }

      try await group.next()
      group.cancelAll()
    }
  }

  static func processExecResponse(
    _ response: StreamingClientResponse<Darvm_ExecResponse>
  ) async throws -> Int32 {
    switch response.accepted {
    case .success(let contents):
      return try await Self.processExecStream(contents.bodyParts)

    case .failure(let error):
      throw error
    }
  }

  static func processExecStream(
    _ bodyParts: RPCAsyncSequence<
      StreamingClientResponse<Darvm_ExecResponse>.Contents.BodyPart, any Error
    >
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
    return 1
  }

  static func streamStdin(to writer: RPCWriter<Darvm_ExecRequest>) async throws {
    let fileDescriptor = FileHandle.standardInput.fileDescriptor
    let stream = AsyncStream<Data> { continuation in
      let source = DispatchSource.makeReadSource(
        fileDescriptor: fileDescriptor,
        queue: DispatchQueue.global(qos: .userInteractive)
      )
      source.setEventHandler {
        let available = source.data
        guard available > 0 else {
          return
        }
        var buf = [UInt8](repeating: 0, count: Int(available))
        let bytesRead = read(fileDescriptor, &buf, buf.count)
        if bytesRead > 0 {
          continuation.yield(Data(buf[..<bytesRead]))
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

    var req = Darvm_ExecRequest()
    req.type = .standardInput(Darvm_IOChunk())
    try await writer.write(req)
  }

  static func streamTerminalResizes(to writer: RPCWriter<Darvm_ExecRequest>) async throws {
    signal(SIGWINCH, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    source.resume()
    defer { source.cancel() }

    let stream = AsyncStream<Void> { continuation in
      source.setEventHandler { continuation.yield() }
      continuation.onTermination = { _ in source.cancel() }
    }

    for await _ in stream {
      guard let (width, height) = try? Term.getSize() else {
        continue
      }
      var size = Darvm_TerminalSize()
      size.cols = UInt32(width)
      size.rows = UInt32(height)
      var req = Darvm_ExecRequest()
      req.type = .terminalResize(size)
      try await writer.write(req)
    }
  }

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
                  guard exit.code == 0 else {
                    return nil
                  }
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
}
