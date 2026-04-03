import Foundation

extension ControlSocket {
  /// Connect to the control socket and send a command.
  static func send(
    _ command: ControlSocketCommand,
    timeout: TimeInterval = 2
  ) -> Result<ControlSocketResponse, ControlSocketClientError> {
    guard FileManager.default.fileExists(atPath: Self.path) else {
      return .failure(.socketNotFound)
    }

    let payload = ["cmd": command.rawValue]
    guard let requestData = try? JSONEncoder().encode(payload) else {
      return .failure(.sendFailed)
    }
    guard let trimmed = performClientRequest(requestData, timeout: timeout) else {
      return .failure(.readTimeout)
    }
    guard let response = try? JSONDecoder().decode(ControlSocketResponse.self, from: trimmed) else {
      return .failure(.decodeFailed)
    }
    return .success(response)
  }

  /// Push credentials to the running VM's sidecar via the control socket.
  /// Returns nil on success, or an error message on failure.
  static func sendLoadCredentials(
    projectName: String,
    secrets: [ResolvedSecret],
    timeout: TimeInterval = 10
  ) -> String? {
    guard FileManager.default.fileExists(atPath: Self.path) else {
      return "VM not running (control socket not found)"
    }

    guard
      let requestData = encodeLoadCredentialsRequest(
        projectName: projectName,
        secrets: secrets
      )
    else {
      return "Failed to encode loadCredentials request"
    }
    guard let response = performClientRequest(requestData, timeout: timeout) else {
      return "Control socket read timed out"
    }
    return decodeStatusOnlyResponse(response)
  }

  /// Tell the running VM to reload its capabilities manifest.
  /// Returns nil on success, or an error message on failure.
  static func sendReloadCapabilities(path: String) -> String? {
    guard FileManager.default.fileExists(atPath: Self.path) else {
      return "VM not running (control socket not found)"
    }

    let payload: [String: Any] = ["cmd": "reloadCapabilities", "path": path]
    guard
      let requestData = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
      )
    else {
      return "Failed to encode reloadCapabilities request"
    }
    guard let response = performClientRequest(requestData, timeout: 5) else {
      return "Control socket read timed out"
    }
    return decodeSimpleResponse(response)
  }

  /// Quick check: is the VM running?
  static func isRunning() -> Bool {
    guard case .success(.status(let payload)) = send(.status) else {
      return false
    }
    return payload.running
  }

  private static func openClientSocket() -> Int32? {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { return nil }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Self.path.utf8CString
    withUnsafeMutablePointer(to: &address.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
        for (index, byte) in pathBytes.enumerated() {
          dest[index] = byte
        }
      }
    }

    let connectResult = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(fileDescriptor, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else {
      close(fileDescriptor)
      return nil
    }

    return fileDescriptor
  }

  private static func performClientRequest(_ requestData: Data, timeout: TimeInterval) -> Data? {
    guard let fileDescriptor = openClientSocket() else { return nil }
    defer { close(fileDescriptor) }

    var data = requestData
    data.append(0x0A)
    _ = data.withUnsafeBytes { ptr in
      write(fileDescriptor, ptr.baseAddress!, data.count)
    }

    var timeoutValue = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(
      fileDescriptor,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeoutValue,
      socklen_t(MemoryLayout<timeval>.size)
    )

    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(fileDescriptor, &buffer, buffer.count)
    guard bytesRead > 0 else { return nil }

    let responseData = Data(buffer[..<bytesRead])
    return trimTrailingWhitespace(responseData)
  }

  private static func trimTrailingWhitespace(_ data: Data) -> Data {
    data.withUnsafeBytes { rawBuffer in
      var end = rawBuffer.count
      while end > 0
        && (rawBuffer[end - 1] == 0x0A || rawBuffer[end - 1] == 0x0D || rawBuffer[end - 1] == 0x20)
      {
        end -= 1
      }
      return Data(rawBuffer.prefix(end))
    }
  }

  private static func encodeLoadCredentialsRequest(
    projectName: String,
    secrets: [ResolvedSecret]
  ) -> Data? {
    let secretDicts: [[String: Any]] = secrets.map { secret in
      [
        "name": secret.name,
        "placeholder": secret.placeholder,
        "value": secret.value,
        "hosts": secret.hosts
      ]
    }
    let payload: [String: Any] = [
      "cmd": "loadCredentials",
      "project_name": projectName,
      "secrets": secretDicts
    ]
    return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  }

  private static func decodeStatusOnlyResponse(_ response: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
      return "Control socket returned invalid JSON"
    }
    if let error = json["error"] as? String {
      return error
    }
    guard json["running"] != nil || json["type"] != nil else {
      return "Control socket returned unexpected response: \(json)"
    }
    return nil
  }

  private static func decodeSimpleResponse(_ response: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
      return "Control socket returned invalid JSON"
    }
    return json["error"] as? String
  }
}
