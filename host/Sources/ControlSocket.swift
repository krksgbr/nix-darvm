import Foundation

/// Lifecycle phases matching the actual boot/activation cycle.
enum VMPhase: String, Codable, Sendable {
  case stopped, configuring, booting, waitingForAgent
  case mounting, activating, running, stopping, failed
}

/// Snapshot of VM status at a point in time.
struct VMStatus: Codable, Sendable {
  let phase: VMPhase
  let ipAddress: String?
  let phaseEnteredAt: TimeInterval  // Unix timestamp (seconds since epoch)
  let runId: String
  let error: String?
}

/// Health info from the guest, queried via vsock.
struct GuestHealthPayload: Codable, Sendable {
  let mounts: [String]
  let activation: String
  let services: [String: String]
}

/// Unix domain socket for CLI coordination.
/// `dvm start` listens; other subcommands connect for instant status/stop.
/// Protocol: newline-delimited JSON request → newline-delimited JSON response.
final class ControlSocket: @unchecked Sendable {
  static let path = "/tmp/dvm-control.sock"

  private var listenerFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private let queue = DispatchQueue(label: "dvm.control")
  private var status = VMStatus(
    phase: .stopped, ipAddress: nil,
    phaseEnteredAt: Date().timeIntervalSince1970,
    runId: "", error: nil
  )

  /// Closure to query guest health via gRPC. Set by Start after agent is connected.
  /// Called from the control socket's dispatch queue (synchronous).
  var guestHealthHandler: (@Sendable () -> GuestHealthPayload?)?

  /// Closure to push credentials to the sidecar. Set by Start after sidecar is ready.
  /// Called from the control socket's dispatch queue (synchronous).
  var loadCredentialsHandler: (@Sendable (String, [[String: Any]]) -> String?)?

  /// Closure to reload the host action bridge's capabilities manifest.
  /// Takes a manifest path (must be in /nix/store/). Returns nil on success, error message on failure.
  var reloadCapabilitiesHandler: (@Sendable (String) -> String?)?

  typealias Command = ControlSocketCommand
  typealias StatusPayload = ControlSocketStatusPayload
  typealias Response = ControlSocketResponse
  typealias ClientError = ControlSocketClientError

  // MARK: - Server (used by `dvm start`)

  func listen() throws {
    cleanup()

    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
      throw ControlSocketError.socketCreationFailed
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Self.path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      close(fileDescriptor)
      throw ControlSocketError.pathTooLong
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
        for (index, byte) in pathBytes.enumerated() {
          dest[index] = byte
        }
      }
    }

    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        bind(fileDescriptor, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      close(fileDescriptor)
      throw ControlSocketError.bindFailed
    }

    guard Darwin.listen(fileDescriptor, 5) == 0 else {
      close(fileDescriptor)
      throw ControlSocketError.listenFailed
    }

    listenerFD = fileDescriptor

    let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
    source.setEventHandler { [weak self] in
      self?.acceptConnection()
    }
    source.setCancelHandler {
      close(fileDescriptor)
    }
    source.resume()
    acceptSource = source
  }

  func update(_ phase: VMPhase, guestIP: GuestIP? = nil, error: String? = nil) {
    queue.sync {
      status = VMStatus(
        phase: phase,
        ipAddress: guestIP?.rawValue ?? status.ipAddress,
        phaseEnteredAt: Date().timeIntervalSince1970,
        runId: DVMLog.runId,
        error: error
      )
    }
  }

  func cleanup() {
    acceptSource?.cancel()
    acceptSource = nil
    if listenerFD >= 0 {
      close(listenerFD)
      listenerFD = -1
    }
    unlink(Self.path)
  }

  private func acceptConnection() {
    let clientFD = accept(listenerFD, nil, nil)
    guard clientFD >= 0 else { return }

    // Read until newline or EOF. The protocol is newline-delimited JSON,
    // and SOCK_STREAM may fragment large payloads (e.g. loadCredentials).
    var requestData = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
      let bytesRead = read(clientFD, &buf, buf.count)
      if bytesRead <= 0 { break }
      requestData.append(buf, count: bytesRead)
      // Newline terminates the request
      if buf[..<bytesRead].contains(0x0A) { break }
    }

    let response = handleRequest(requestData.isEmpty ? nil : requestData)

    if var responseData = try? JSONEncoder().encode(response) {
      responseData.append(0x0A)  // newline
      _ = responseData.withUnsafeBytes { ptr in
        write(clientFD, ptr.baseAddress!, responseData.count)
      }
    }
    close(clientFD)
  }

  private func handleRequest(_ data: Data?) -> Response {
    guard let decoded = decodeRequest(data) else {
      return .error(message: "invalid request: expected JSON with \"cmd\" field")
    }
    guard let command = parseCommand(from: decoded) else {
      let commandString = decoded["cmd"] as? String ?? ""
      return .error(message: "unknown command: \(commandString)")
    }

    switch command {
    case .status:
      return statusResponse()
    case .guestHealth:
      return guestHealthResponse()
    case .loadCredentials:
      return loadCredentialsResponse(decoded)
    case .reloadCapabilities:
      return reloadCapabilitiesResponse(decoded)
    }
  }

  private func decodeRequest(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func parseCommand(from decoded: [String: Any]) -> Command? {
    guard let commandString = decoded["cmd"] as? String else { return nil }
    return Command(rawValue: commandString)
  }

  private func statusResponse() -> Response {
    let currentStatus = status
    let running = currentStatus.phase != .stopped && currentStatus.phase != .failed
    return .status(
      StatusPayload(
        running: running,
        ipAddress: currentStatus.ipAddress,
        phase: currentStatus.phase.rawValue,
        runId: currentStatus.runId,
        phaseEnteredAt: currentStatus.phaseEnteredAt,
        phaseError: currentStatus.error
      ))
  }

  private func guestHealthResponse() -> Response {
    guard let handler = guestHealthHandler else {
      return .error(message: "guest health not available (VM not fully started)")
    }
    guard let health = handler() else {
      return .error(message: "guest health query failed")
    }
    return .guestHealth(health)
  }

  private func loadCredentialsResponse(_ decoded: [String: Any]) -> Response {
    guard let handler = loadCredentialsHandler else {
      return .error(message: "credential proxy not available (sidecar not running)")
    }
    guard let projectName = decoded["project_name"] as? String, !projectName.isEmpty else {
      return .error(message: "loadCredentials: missing project_name")
    }
    guard let secrets = decoded["secrets"] as? [[String: Any]] else {
      return .error(message: "loadCredentials: missing or invalid secrets array")
    }
    if let errorMessage = handler(projectName, secrets) {
      return .error(message: errorMessage)
    }
    return successStatusResponse()
  }

  private func reloadCapabilitiesResponse(_ decoded: [String: Any]) -> Response {
    guard let handler = reloadCapabilitiesHandler else {
      return .error(message: "host action bridge not available")
    }
    guard let path = decoded["path"] as? String, !path.isEmpty else {
      return .error(message: "reloadCapabilities: missing path")
    }
    if let errorMessage = handler(path) {
      return .error(message: errorMessage)
    }
    return successStatusResponse()
  }

  private func successStatusResponse() -> Response {
    .status(
      StatusPayload(
        running: true,
        ipAddress: nil,
        phase: nil,
        runId: nil,
        phaseEnteredAt: nil,
        phaseError: nil
      ))
  }
}
