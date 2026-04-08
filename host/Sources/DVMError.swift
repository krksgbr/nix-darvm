import Foundation

enum DVMError: Error, CustomStringConvertible {
  case noIPAddress
  case buildFailed
  case invalidStorePath(String)
  case activationFailed(String)
  case alreadyRunning
  case portBindFailed(port: UInt16)
  case setupFailed(String)

  var description: String {
    switch self {
    case .noIPAddress:
      return "Could not resolve VM IP address. Is the VM running?"

    case .buildFailed:
      return "nix build failed"

    case .invalidStorePath(let storePath):
      return "Invalid nix store path from build output: \(storePath)"

    case .activationFailed(let message):
      return "Activation failed: \(message)"

    case .alreadyRunning:
      return "A VM is already running. Stop it first or use `dvm switch` to apply changes."

    case .portBindFailed(let port):
      return "Port forwarding failed: could not bind localhost:\(port). Is another process using it?"

    case .setupFailed(let message):
      return "VM setup failed: \(message)"
    }
  }
}
