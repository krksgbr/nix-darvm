import ArgumentParser
import Foundation

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

    let credentialEnv: [String: String]
    do {
      credentialEnv = try resolveAndPushCredentials(
        credentialsFlag: credentials, cwd: cwd)
    } catch let error as SecretConfigError {
      switch error {
      case .envVarNotSet, .envVarEmpty:
        fputs("Warning: credential resolution warning: \(error)\n", stderr)
        credentialEnv = [:]
      default:
        throw error
      }
    }

    let exitCode = try await agentClient.execInteractive(
      command: ["/bin/zsh", "-l"],
      cwd: cwd,
      tty: true,
      env: credentialEnv
    )
    throw ExitCode(exitCode)
  }
}
