import Foundation

/// Lifecycle phases matching the actual boot/activation cycle.
enum VMPhase: String, Codable, Sendable {
    case stopped, configuring, booting, waitingForAgent
    case mounting, activating, running, stopping, failed
}

/// Snapshot of VM status at a point in time.
struct VMStatus: Codable, Sendable {
    let phase: VMPhase
    let ip: String?
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
        phase: .stopped, ip: nil,
        phaseEnteredAt: Date().timeIntervalSince1970,
        runId: "", error: nil
    )

    /// Closure to query guest health via gRPC. Set by Start after agent is connected.
    /// Called from the control socket's dispatch queue (synchronous).
    var guestHealthHandler: (@Sendable () -> GuestHealthPayload?)?

    // MARK: - Wire protocol

    enum Command: String, Codable {
        case status
        case guestHealth
    }

    struct StatusPayload: Codable {
        let running: Bool
        let ip: String?
        // New observability fields (optional for backward compat)
        let phase: String?
        let runId: String?
        let phaseEnteredAt: Double?
        let phaseError: String?
    }

    enum Response: Codable {
        case status(StatusPayload)
        case guestHealth(GuestHealthPayload)
        case error(message: String)

        enum CodingKeys: String, CodingKey {
            case running, ip, error, phase, runId, phaseEnteredAt, phaseError
            case type, mounts, activation, services
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .status(let payload):
                try container.encode(payload.running, forKey: .running)
                try container.encodeIfPresent(payload.ip, forKey: .ip)
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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let error = try container.decodeIfPresent(String.self, forKey: .error) {
                self = .error(message: error)
            } else if let type = try container.decodeIfPresent(String.self, forKey: .type),
                      type == "guestHealth" {
                let mounts = try container.decode([String].self, forKey: .mounts)
                let activation = try container.decode(String.self, forKey: .activation)
                let services = try container.decode([String: String].self, forKey: .services)
                self = .guestHealth(GuestHealthPayload(
                    mounts: mounts, activation: activation, services: services
                ))
            } else {
                let running = try container.decode(Bool.self, forKey: .running)
                let ip = try container.decodeIfPresent(String.self, forKey: .ip)
                let phase = try container.decodeIfPresent(String.self, forKey: .phase)
                let runId = try container.decodeIfPresent(String.self, forKey: .runId)
                let phaseEnteredAt = try container.decodeIfPresent(Double.self, forKey: .phaseEnteredAt)
                let phaseError = try container.decodeIfPresent(String.self, forKey: .phaseError)
                self = .status(StatusPayload(
                    running: running, ip: ip, phase: phase, runId: runId,
                    phaseEnteredAt: phaseEnteredAt, phaseError: phaseError
                ))
            }
        }
    }

    // MARK: - Server (used by `dvm start`)

    func listen() throws {
        cleanup()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Self.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ControlSocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ControlSocketError.bindFailed
        }

        guard Darwin.listen(fd, 5) == 0 else {
            close(fd)
            throw ControlSocketError.listenFailed
        }

        listenerFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source
    }

    func update(_ phase: VMPhase, ip: GuestIP? = nil, error: String? = nil) {
        queue.sync {
            status = VMStatus(
                phase: phase,
                ip: ip?.rawValue ?? status.ip,
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

        // Read request (up to 1KB, single line)
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = read(clientFD, &buf, buf.count)

        let response = handleRequest(n > 0 ? Data(buf[..<n]) : nil)

        if var responseData = try? JSONEncoder().encode(response) {
            responseData.append(0x0A) // newline
            _ = responseData.withUnsafeBytes { ptr in
                write(clientFD, ptr.baseAddress!, responseData.count)
            }
        }
        close(clientFD)
    }

    private func handleRequest(_ data: Data?) -> Response {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data),
              let cmdStr = decoded["cmd"] else {
            return .error(message: "invalid request: expected JSON with \"cmd\" field")
        }
        guard let command = Command(rawValue: cmdStr) else {
            return .error(message: "unknown command: \(cmdStr)")
        }

        switch command {
        case .status:
            let s = status
            let running = s.phase != .stopped && s.phase != .failed
            return .status(StatusPayload(
                running: running,
                ip: s.ip,
                phase: s.phase.rawValue,
                runId: s.runId,
                phaseEnteredAt: s.phaseEnteredAt,
                phaseError: s.error
            ))
        case .guestHealth:
            guard let handler = guestHealthHandler else {
                return .error(message: "guest health not available (VM not fully started)")
            }
            if let health = handler() {
                return .guestHealth(health)
            } else {
                return .error(message: "guest health query failed")
            }
        }
    }

    // MARK: - Client (used by other subcommands)

    enum ClientError: Error, CustomStringConvertible {
        case socketNotFound
        case connectFailed(String)
        case sendFailed
        case readTimeout
        case decodeFailed

        var description: String {
            switch self {
            case .socketNotFound: return "Control socket not found (VM not running?)"
            case .connectFailed(let reason): return "Control socket connect failed: \(reason)"
            case .sendFailed: return "Failed to send command to control socket"
            case .readTimeout: return "Control socket read timed out"
            case .decodeFailed: return "Failed to decode control socket response"
            }
        }
    }

    /// Connect to the control socket and send a command.
    static func send(_ command: Command, timeout: TimeInterval = 2) -> Result<Response, ClientError> {
        guard FileManager.default.fileExists(atPath: Self.path) else {
            return .failure(.socketNotFound)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(.connectFailed(String(cString: strerror(errno))))
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Self.path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            return .failure(.connectFailed(String(cString: strerror(errno))))
        }

        // Send command as JSON
        guard var requestData = try? JSONEncoder().encode(["cmd": command.rawValue]) else {
            return .failure(.sendFailed)
        }
        requestData.append(0x0A) // newline
        _ = requestData.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!, requestData.count)
        }

        // Set read timeout
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return .failure(.readTimeout) }

        let trimmed = Data(buf[..<n]).withUnsafeBytes { rawBuf in
            var end = n
            while end > 0 && (rawBuf[end - 1] == 0x0A || rawBuf[end - 1] == 0x0D || rawBuf[end - 1] == 0x20) {
                end -= 1
            }
            return Data(rawBuf.prefix(end))
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: trimmed) else {
            return .failure(.decodeFailed)
        }
        return .success(response)
    }

    /// Quick check: is the VM running?
    static func isRunning() -> Bool {
        guard case .success(.status(let payload)) = send(.status) else {
            return false
        }
        return payload.running
    }
}

enum ControlSocketError: Error, CustomStringConvertible {
    case socketCreationFailed
    case pathTooLong
    case bindFailed
    case listenFailed

    var description: String {
        switch self {
        case .socketCreationFailed: return "Failed to create control socket"
        case .pathTooLong: return "Control socket path too long"
        case .bindFailed: return "Failed to bind control socket"
        case .listenFailed: return "Failed to listen on control socket"
        }
    }
}
