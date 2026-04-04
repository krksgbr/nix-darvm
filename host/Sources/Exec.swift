import ArgumentParser
import Foundation

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
