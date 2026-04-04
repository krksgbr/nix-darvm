import Foundation

enum ControlSocketCommand: String, Codable {
  case status
  case guestHealth
  case loadCredentials
  case reloadCapabilities
}

struct ControlSocketStatusPayload: Codable {
  let running: Bool
  let ipAddress: String?
  let phase: String?
  let runId: String?
  let phaseEnteredAt: Double?
  let phaseError: String?

  enum CodingKeys: String, CodingKey {
    case running = "running"
    case ipAddress = "ip"
    case phase = "phase"
    case runId = "runId"
    case phaseEnteredAt = "phaseEnteredAt"
    case phaseError = "phaseError"
  }
}

enum ControlSocketResponse: Codable {
  case status(ControlSocketStatusPayload)
  case guestHealth(GuestHealthPayload)
  case error(message: String)

  enum CodingKeys: String, CodingKey {
    case running = "running"
    case ipAddress = "ip"
    case error = "error"
    case phase = "phase"
    case runId = "runId"
    case phaseEnteredAt = "phaseEnteredAt"
    case phaseError = "phaseError"
    case type = "type"
    case mounts = "mounts"
    case activation = "activation"
    case services = "services"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let error = try container.decodeIfPresent(String.self, forKey: .error) {
      self = .error(message: error)
    } else if let type = try container.decodeIfPresent(String.self, forKey: .type),
      type == "guestHealth"
    {
      let mounts = try container.decode([String].self, forKey: .mounts)
      let activation = try container.decode(String.self, forKey: .activation)
      let services = try container.decode([String: String].self, forKey: .services)
      self = .guestHealth(
        GuestHealthPayload(
          mounts: mounts,
          activation: activation,
          services: services
        )
      )
    } else {
      let running = try container.decode(Bool.self, forKey: .running)
      let ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
      let phase = try container.decodeIfPresent(String.self, forKey: .phase)
      let runId = try container.decodeIfPresent(String.self, forKey: .runId)
      let phaseEnteredAt = try container.decodeIfPresent(Double.self, forKey: .phaseEnteredAt)
      let phaseError = try container.decodeIfPresent(String.self, forKey: .phaseError)
      self = .status(
        ControlSocketStatusPayload(
          running: running,
          ipAddress: ipAddress,
          phase: phase,
          runId: runId,
          phaseEnteredAt: phaseEnteredAt,
          phaseError: phaseError
        )
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .status(let payload):
      try container.encode(payload.running, forKey: .running)
      try container.encodeIfPresent(payload.ipAddress, forKey: .ipAddress)
      try container.encodeIfPresent(payload.phase, forKey: .phase)
      try container.encodeIfPresent(payload.runId, forKey: .runId)
      try container.encodeIfPresent(payload.phaseEnteredAt, forKey: .phaseEnteredAt)
      try container.encodeIfPresent(payload.phaseError, forKey: .phaseError)

    case .guestHealth(let payload):
      try container.encode("guestHealth", forKey: .type)
      try container.encode(payload.mounts, forKey: .mounts)
      try container.encode(payload.activation, forKey: .activation)
      try container.encode(payload.services, forKey: .services)

    case .error(let message):
      try container.encode(message, forKey: .error)
    }
  }
}

enum ControlSocketClientError: Error, CustomStringConvertible {
  case socketNotFound
  case connectFailed(String)
  case sendFailed
  case readTimeout
  case decodeFailed

  var description: String {
    switch self {
    case .socketNotFound:
      return "Control socket not found (VM not running?)"

    case .connectFailed(let reason):
      return "Control socket connect failed: \(reason)"

    case .sendFailed:
      return "Failed to send command to control socket"

    case .readTimeout:
      return "Control socket read timed out"

    case .decodeFailed:
      return "Failed to decode control socket response"
    }
  }
}

enum ControlSocketError: Error, CustomStringConvertible {
  case socketCreationFailed
  case pathTooLong
  case bindFailed
  case listenFailed

  var description: String {
    switch self {
    case .socketCreationFailed:
      return "Failed to create control socket"

    case .pathTooLong:
      return "Control socket path too long"

    case .bindFailed:
      return "Failed to bind control socket"

    case .listenFailed:
      return "Failed to listen on control socket"
    }
  }
}
