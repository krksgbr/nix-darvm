import Foundation

/// Manages the dvm-netstack sidecar process lifecycle.
///
/// Creates a socketpair for raw Ethernet frame I/O between the VZ framework
/// and the Go sidecar. The sidecar runs gVisor netstack for transparent
/// credential injection. Secrets are passed via a JSON control socket —
/// never via argv or environment variables.
///
/// On sidecar crash, networking fails closed. There is no silent fallback to NAT.
final class NetstackSupervisor: @unchecked Sendable {
  /// The file descriptor for the VM-side of the socketpair.
  /// Pass this to VZFileHandleNetworkDeviceAttachment.
  let vmFD: Int32

  /// Path to the sidecar's control socket.
  let controlSocketPath: String

  private let process: Process
  private let onCrash: @Sendable () -> Void

  /// Set before initiating a controlled shutdown so the monitor doesn't fire onCrash.
  private let _shuttingDown = LockedBool()

  struct Config: Sendable {
    let netstackBinary: String
    let subnet: String
    let gatewayIP: String
    let guestIP: String
    let guestMAC: String
    let dnsServers: [String]
    let caCertPEM: String
    let caKeyPEM: String
  }

  enum SupervisorError: Error, CustomStringConvertible {
    case socketpairFailed(Int32)
    case sidecarNotFound(String)
    case sidecarStartFailed(String)
    case controlSocketTimeout
    case controlSocketError(String)
    case sidecarCrashed(Int32)

    var description: String {
      switch self {
      case .socketpairFailed(let code):
        return "socketpair(AF_UNIX, SOCK_DGRAM) failed: \(String(cString: strerror(code)))"

      case .sidecarNotFound(let name):
        return "Sidecar binary not found: \(name)"

      case .sidecarStartFailed(let detail):
        return "Failed to start sidecar: \(detail)"

      case .controlSocketTimeout:
        return "Sidecar control socket did not appear within timeout"

      case .controlSocketError(let msg):
        return "Sidecar control socket error: \(msg)"

      case .sidecarCrashed(let code):
        return "Sidecar crashed (exit code \(code)) — networking is down"
      }
    }
  }

  /// Launch the sidecar. Returns a supervisor with the sidecar running.
  /// Call `configure(config:)` next to send CA + secrets via the control socket.
  ///
  /// - Parameters:
  ///   - config: CA certificate, key, resolved secrets, and binary path
  ///   - onCrash: Called if the sidecar process exits unexpectedly. Must fail loudly.
  static func launch(
    config: Config,
    onCrash: @escaping @Sendable () -> Void
  ) throws -> NetstackSupervisor {
    // Create socketpair for raw Ethernet frame exchange (DGRAM = one frame per read/write)
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
      throw SupervisorError.socketpairFailed(errno)
    }
    let vmFD = fds[0]
    let sidecarFD = fds[1]

    // Control socket path
    let controlPath = "/tmp/dvm-netstack-\(ProcessInfo.processInfo.processIdentifier).sock"
    unlink(controlPath)  // clean up stale socket

    // Resolve sidecar binary
    let binaryPath = config.netstackBinary
    guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
      close(vmFD)
      close(sidecarFD)
      throw SupervisorError.sidecarNotFound(binaryPath)
    }

    // Pass the socketpair FD to the sidecar as stdin.
    // Swift's Process/NSTask doesn't inherit arbitrary FDs (it uses posix_spawn
    // which closes all non-standard FDs). Passing via stdin is the reliable way.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = [
      "--frame-fd", "0",  // stdin = the socketpair
      "--control-sock", controlPath
    ]
    process.standardInput = FileHandle(fileDescriptor: sidecarFD, closeOnDealloc: false)

    // Only pass safe environment variables. The sidecar doesn't need
    // arbitrary host env (which may contain unrelated secrets like AWS keys).
    // Real credentials are delivered via the control socket, never via env.
    let safeKeys: Set<String> = [
      "PATH", "HOME", "USER", "SHELL", "TERM", "LANG", "LC_ALL",
      "TMPDIR", "XDG_RUNTIME_DIR"
    ]
    process.environment = ProcessInfo.processInfo.environment
      .filter { safeKeys.contains($0.key) }

    do {
      try process.run()
    } catch {
      close(vmFD)
      close(sidecarFD)
      throw SupervisorError.sidecarStartFailed("\(error)")
    }

    // Close the sidecar's end in the parent — child owns it now
    close(sidecarFD)

    return NetstackSupervisor(
      vmFD: vmFD,
      controlSocketPath: controlPath,
      process: process,
      onCrash: onCrash
    )
  }

  private init(
    vmFD: Int32,
    controlSocketPath: String,
    process: Process,
    onCrash: @escaping @Sendable () -> Void
  ) {
    self.vmFD = vmFD
    self.controlSocketPath = controlSocketPath
    self.process = process
    self.onCrash = onCrash
  }

  /// The CA cert PEM returned by the sidecar (available after configure()).
  private(set) var caCertPEM: String = ""

  /// Wait for the control socket to appear, connect, and send initial config.
  /// The sidecar generates the CA and returns it in the ready response.
  func configure(config: Config) throws {
    // Wait for control socket to appear (sidecar creates it)
    let deadline = Date().addingTimeInterval(30)  // longer timeout: sidecar generates CA
    while !FileManager.default.fileExists(atPath: controlSocketPath) {
      guard Date() < deadline else {
        throw SupervisorError.controlSocketTimeout
      }
      Thread.sleep(forTimeInterval: 0.1)
    }

    // Send initial load_config with network config and secrets.
    // CA PEM fields are empty — sidecar generates the CA in Go.
    let loadMessage = buildLoadMessage(config: config)
    let response = try sendControlMessage(loadMessage)
    guard response["type"] as? String == "ready" else {
      let error = response["error"] as? String ?? "unknown error"
      throw SupervisorError.controlSocketError(error)
    }
    // Extract the sidecar-generated CA cert PEM for guest trust store installation
    caCertPEM = response["ca_cert_pem"] as? String ?? ""
  }

  /// Start monitoring the sidecar process. Calls `onCrash` if it exits unexpectedly.
  func startMonitoring() {
    let crashHandler = onCrash
    let proc = process
    let shuttingDown = _shuttingDown
    DispatchQueue.global(qos: .utility).async {
      proc.waitUntilExit()
      let code = proc.terminationStatus
      if shuttingDown.value {
        DVMLog.log("dvm-netstack exited during shutdown (code \(code))")
      } else {
        DVMLog.log(level: "error", "dvm-netstack exited with code \(code)")
        crashHandler()
      }
    }
  }

  /// Gracefully shut down the sidecar.
  func shutdown() {
    _shuttingDown.set(true)

    // Send shutdown command via control socket
    let msg: [String: Any] = ["type": "shutdown"]
    _ = try? sendControlMessage(msg)

    // Wait briefly for graceful exit
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
    }

    // Force kill if still running
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }

    // Clean up
    close(vmFD)
    unlink(controlSocketPath)
  }

  /// Push credentials for a project to the sidecar. Same project name
  /// overwrites previous mappings (last writer wins).
  func loadCredentials(projectName: String, secrets: [ResolvedSecret]) throws {
    let msg: [String: Any] = [
      "type": "load",
      "project_name": projectName,
      "secrets": secrets.map { encodeSecret($0) }
    ]
    let response = try sendControlMessage(msg)
    guard response["type"] as? String == "ok" else {
      let error = response["error"] as? String ?? "unknown error"
      throw SupervisorError.controlSocketError(error)
    }
  }

  // MARK: - Private

  private func encodeSecret(_ secret: ResolvedSecret) -> [String: Any] {
    [
      "name": secret.name,
      "placeholder": secret.placeholder,
      "value": secret.value,
      "hosts": secret.hosts
    ]
  }

  private func buildLoadMessage(config: Config) -> [String: Any] {
    [
      "type": "load_config",
      "config": [
        "subnet": config.subnet,
        "gateway_ip": config.gatewayIP,
        "guest_ip": config.guestIP,
        "guest_mac": config.guestMAC,
        "dns_servers": config.dnsServers,
        "ca_cert_pem": config.caCertPEM,
        "ca_key_pem": config.caKeyPEM,
        "secrets": [] as [[String: Any]]
      ] as [String: Any]
    ]
  }

  /// Send a JSON message to the control socket and read the response.
  private func sendControlMessage(_ message: [String: Any]) throws -> [String: Any] {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
      throw SupervisorError.controlSocketError(
        "failed to create socket: \(String(cString: strerror(errno)))")
    }
    defer { close(fileDescriptor) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = controlSocketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
        for (index, byte) in pathBytes.enumerated() {
          dest[index] = byte
        }
      }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(fileDescriptor, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else {
      throw SupervisorError.controlSocketError(
        "connect to \(controlSocketPath) failed: \(String(cString: strerror(errno)))")
    }

    // Send JSON
    let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
    let sent = data.withUnsafeBytes { ptr in
      guard let baseAddress = ptr.baseAddress else {
        return 0
      }
      return write(fileDescriptor, baseAddress, ptr.count)
    }
    guard sent == data.count else {
      throw SupervisorError.controlSocketError("short write to control socket")
    }
    Darwin.shutdown(fileDescriptor, SHUT_WR)

    // Read response
    var responseData = Data()
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4_096, alignment: 1)
    defer { buf.deallocate() }
    while true {
      let bytesRead = read(fileDescriptor, buf, 4_096)
      if bytesRead <= 0 { break }
      responseData.append(buf.assumingMemoryBound(to: UInt8.self), count: bytesRead)
    }

    guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
      throw SupervisorError.controlSocketError("invalid JSON response from sidecar")
    }
    return json
  }
}

/// Thread-safe boolean flag. Minimal lock-based wrapper for cross-queue signaling.
final class LockedBool: @unchecked Sendable {
  private var _value = false
  private let lock = NSLock()

  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }

  func set(_ newValue: Bool) {
    lock.lock()
    defer { lock.unlock() }
    _value = newValue
  }
}
