import Foundation
@preconcurrency import Virtualization

/// Bridges vsock connections from the guest to the host's nix daemon socket.
///
/// When a guest process connects to vsock port `listenPort`, we open a connection
/// to the host's nix daemon Unix socket and proxy data bidirectionally.
@MainActor
final class VsockDaemonBridge {
  static let defaultPort: UInt32 = 6174
  static let defaultDaemonSocket = "/nix/var/nix/daemon-socket/socket"

  let socketDevice: VZVirtioSocketDevice
  let listenPort: UInt32
  let daemonSocketPath: String

  init(
    virtualMachine: VZVirtualMachine,
    listenPort: UInt32 = defaultPort,
    daemonSocketPath: String = defaultDaemonSocket
  ) throws {
    guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
      throw BridgeError.noSocketDevice
    }
    self.socketDevice = device
    self.listenPort = listenPort
    self.daemonSocketPath = daemonSocketPath
  }

  /// Start listening for guest vsock connections.
  func start() {
    let listener = VZVirtioSocketListener()
    let delegate = ListenerDelegate(bridge: self)
    self.listenerDelegate = delegate
    listener.delegate = delegate
    socketDevice.setSocketListener(listener, forPort: listenPort)
    print("Nix daemon bridge listening on vsock port \(listenPort)")
    fflush(stdout)
  }

  private var listenerDelegate: ListenerDelegate?

  /// Handle an incoming vsock connection from the guest.
  /// Blocks until the proxy session ends — must be called from a background thread.
  /// The `connection` object must stay alive for the duration (VZVirtioSocketConnection
  /// tears down the vsock channel on dealloc).
  nonisolated func handleConnection(_ connection: VZVirtioSocketConnection) {
    let vsockFD = connection.fileDescriptor

    guard let daemonFD = connectToDaemonSocket(path: daemonSocketPath) else {
      return
    }

    // Proxy data bidirectionally. Block until both directions finish so that
    // `connection` stays alive for the duration.
    let group = DispatchGroup()
    proxyAsync(group: group, readFD: vsockFD, writeFD: daemonFD, direction: "vsock→daemon")
    proxyAsync(group: group, readFD: daemonFD, writeFD: vsockFD, direction: "daemon→vsock")

    group.wait()
    close(daemonFD)
  }

  private nonisolated func connectToDaemonSocket(path: String) -> Int32? {
    let daemonFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard daemonFD >= 0 else {
      let err = String(cString: strerror(errno))
      fputs("Bridge: failed to create Unix socket: \(err)\n", stderr)
      return nil
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      fputs("Bridge: daemon socket path too long: \(path)\n", stderr)
      close(daemonFD)
      return nil
    }
    withUnsafeMutablePointer(to: &address.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
        for (index, byte) in pathBytes.enumerated() {
          dest[index] = byte
        }
      }
    }

    let connectResult = withUnsafePointer(to: &address) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(daemonFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else {
      let err = String(cString: strerror(errno))
      fputs("Bridge: failed to connect to \(path): \(err)\n", stderr)
      close(daemonFD)
      return nil
    }

    return daemonFD
  }

  private nonisolated func proxyAsync(
    group: DispatchGroup,
    readFD: Int32,
    writeFD: Int32,
    direction: String
  ) {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      self.proxy(readFD: readFD, writeFD: writeFD, direction: direction)
    }
  }

  private nonisolated func proxy(readFD: Int32, writeFD: Int32, direction: String) {
    let bufferSize = 32768
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
    defer { buffer.deallocate() }

    while true {
      let bytesRead = read(readFD, buffer, bufferSize)
      if bytesRead <= 0 {
        if bytesRead < 0 {
          let err = String(cString: strerror(errno))
          fputs("Bridge: \(direction) read error: \(err)\n", stderr)
        }
        break
      }
      guard writeAll(from: buffer, byteCount: bytesRead, to: writeFD, direction: direction) else {
        return
      }
    }

    shutdown(writeFD, SHUT_WR)
  }

  private nonisolated func writeAll(
    from buffer: UnsafeMutableRawPointer,
    byteCount: Int,
    to fileDescriptor: Int32,
    direction: String
  ) -> Bool {
    var written = 0
    while written < byteCount {
      let bytesWritten = write(fileDescriptor, buffer + written, byteCount - written)
      if bytesWritten <= 0 {
        let err = String(cString: strerror(errno))
        fputs("Bridge: \(direction) write error: \(err)\n", stderr)
        return false
      }
      written += bytesWritten
    }
    return true
  }
}

// MARK: - VZVirtioSocketListenerDelegate

extension VsockDaemonBridge {
  final class ListenerDelegate: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    let bridge: VsockDaemonBridge

    init(bridge: VsockDaemonBridge) {
      self.bridge = bridge
    }

    nonisolated func listener(
      _ listener: VZVirtioSocketListener,
      shouldAcceptNewConnection connection: VZVirtioSocketConnection,
      from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
      nonisolated(unsafe) let conn = connection
      DispatchQueue.global(qos: .utility).async {
        self.bridge.handleConnection(conn)
      }
      return true
    }
  }
}

enum BridgeError: Error, CustomStringConvertible {
  case noSocketDevice

  var description: String {
    switch self {
    case .noSocketDevice: return "No VZVirtioSocketDevice found on the VM"
    }
  }
}
