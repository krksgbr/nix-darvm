import ArgumentParser
import Foundation

struct Stop: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Gracefully shut down the VM"
  )

  func run() async throws {
    let agentClient = AgentClient()
    do {
      print("Shutting down VM...")
      _ = try await agentClient.exec(
        command: ["sudo", "shutdown", "-h", "now"]
      )
    } catch {
      if case .failure(.socketNotFound) = ControlSocket.send(.status) {
        print("VM not running.")
      } else {
        print("Shutdown command failed: \(error)")
      }
    }
  }
}
