import ArgumentParser
import Foundation

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
