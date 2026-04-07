import ArgumentParser
import Foundation

struct Status: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show VM status"
  )

  @Flag(name: .long, help: "Output as JSON")
  var json: Bool = false

  func run() throws {
    if json {
      try outputJSON()
    } else {
      try outputHuman()
    }
  }

  private func outputJSON() throws {
    var result: [String: Any] = ["running": false]

    switch ControlSocket.send(.status) {
    case .success(.status(let payload)):
      populateStatusJSON(&result, from: payload)
      addGuestHealthJSON(&result, status: payload)

    case .failure:
      break

    default:
      break
    }

    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    guard let output = String(data: data, encoding: .utf8) else {
      throw DVMError.activationFailed("status response was not valid UTF-8")
    }
    print(output)

    if result["running"] as? Bool != true {
      throw ExitCode(1)
    }
  }

  private func populateStatusJSON(
    _ result: inout [String: Any],
    from payload: ControlSocketStatusPayload
  ) {
    result["running"] = payload.running
    if let phase = payload.phase { result["phase"] = phase }
    if let ipAddress = payload.ipAddress { result["ip"] = ipAddress }
    if let runId = payload.runId { result["run_id"] = runId }
    if let phaseError = payload.phaseError { result["error"] = phaseError }
  }

  private func addGuestHealthJSON(
    _ result: inout [String: Any],
    status payload: ControlSocketStatusPayload
  ) {
    guard payload.running, payload.phase == VMPhase.running.rawValue else {
      return
    }
    guard case .success(.guestHealth(let health)) = ControlSocket.send(.guestHealth, timeout: 5)
    else {
      return
    }
    result["mounts"] = health.mounts
    result["activation"] = health.activation
    result["services"] = health.services
  }

  private func outputHuman() throws {
    let statusResult = ControlSocket.send(.status)
    switch statusResult {
    case .success(.status(let payload)):
      guard payload.running else {
        try printStoppedStatus(payload)
        return
      }
      print(statusSummaryLine(payload))
      if let runId = payload.runId {
        print("  Run:        \(runId)")
      }

      if payload.phase == VMPhase.running.rawValue {
        printGuestHealthSummary()
      }

    default:
      try throwStatusFailure(statusResult)
    }
  }
}
