import Foundation
import NIOCore
import NIOPosix
@preconcurrency import Virtualization

private let portForwardHalfCloseConfig = NIOAsyncChannel<ByteBuffer, ByteBuffer>.Configuration(
  isOutboundHalfClosureEnabled: true
)

/// Forwards TCP connections from host localhost ports to guest localhost ports
/// via vsock port 6177.
///
/// For each configured port mapping, a TCP listener binds on the host.
/// When a client connects, we dial vsock 6177, write a 2-byte big-endian
/// target port header, then proxy bidirectionally.
///
/// IMPORTANT: The `VZVirtioSocketConnection` must be retained for the full
/// session duration. Deallocation tears down the vsock channel immediately.
@MainActor
final class PortForwarder {
  static let vsockPort: UInt32 = 6_177

  struct PortMapping {
    let hostPort: UInt16
    let guestPort: UInt16
  }

  /// Holds a vsock connection and its raw fd together.
  /// The connection object MUST be retained for the session duration —
  /// VZVirtioSocketConnection tears down the channel on dealloc.
  struct VsockHandle: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
    let fileDescriptor: Int32
  }

  /// A bound server channel paired with its port mapping.
  private struct BoundListener: Sendable {
    let channel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    let mapping: PortMapping
  }

  let mappings: [PortMapping]
  let socketDevice: VZVirtioSocketDevice
  private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  private var serverTasks: [Task<Void, Error>] = []

  init(
    virtualMachine: VZVirtualMachine,
    mappings: [PortMapping]
  ) throws {
    guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
      throw BridgeError.noSocketDevice
    }
    self.socketDevice = device
    self.mappings = mappings
  }

  /// Start TCP listeners for all configured port mappings.
  /// Binds all ports synchronously first — if any bind fails, all already-bound
  /// listeners are closed and the error is propagated. Accept loops are only
  /// spawned after all binds succeed.
  func start() async throws {
    var boundListeners: [BoundListener] = []

    do {
      for mapping in mappings {
        let serverChannel = try await ServerBootstrap(group: eventLoopGroup)
          .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
          .bind(host: "127.0.0.1", port: Int(mapping.hostPort)) { childChannel in
            childChannel.eventLoop.makeCompletedFuture {
              try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: childChannel,
                configuration: portForwardHalfCloseConfig
              )
            }
          }
        boundListeners.append(BoundListener(channel: serverChannel, mapping: mapping))
      }
    } catch {
      // Close all already-bound listeners on failure.
      for listener in boundListeners {
        try? await listener.channel.channel.close()
      }
      throw error
    }

    // All binds succeeded — spawn the accept loops.
    for listener in boundListeners {
      DVMLog.log(
        phase: nil,
        "port forward: localhost:\(listener.mapping.hostPort) -> guest:\(listener.mapping.guestPort)"
      )
      let task = Task {
        try await self.runAcceptLoop(listener: listener)
      }
      serverTasks.append(task)
    }
  }

  func stop() {
    for task in serverTasks {
      task.cancel()
    }
    serverTasks.removeAll()
    try? eventLoopGroup.syncShutdownGracefully()
  }

  /// Connect to the guest's port-forward vsock service.
  /// Must be called on MainActor since VZVirtioSocketDevice requires it.
  func connectToVM() async throws -> VsockHandle {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<VsockHandle, Error>) in
      socketDevice.connect(toPort: Self.vsockPort) { result in
        switch result {
        case .success(let conn):
          cont.resume(
            returning: VsockHandle(
              connection: conn,
              fileDescriptor: conn.fileDescriptor
            ))

        case .failure(let error):
          cont.resume(throwing: error)
        }
      }
    }
  }

  private func runAcceptLoop(listener: BoundListener) async throws {
    try await withThrowingDiscardingTaskGroup { group in
      try await listener.channel.executeThenClose { serverInbound in
        for try await clientChannel in serverInbound {
          group.addTask {
            await self.handleClient(clientChannel, guestPort: listener.mapping.guestPort)
          }
        }
      }
    }
  }

  nonisolated private func handleClient(
    _ clientChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
    guestPort: UInt16
  ) async {
    let connId = UInt32.random(in: 0...0xFFFF)

    do {
      try await clientChannel.executeThenClose { clientInbound, clientOutbound in
        DVMLog.log(
          level: "debug",
          "port-fwd[\(connId)]: client connected, forwarding to guest:\(guestPort)")

        // Connect to guest's port-forward vsock service
        let vsockHandle = try await self.connectToVM()
        DVMLog.log(
          level: "debug",
          "port-fwd[\(connId)]: vsock connected (fd=\(vsockHandle.fileDescriptor))")

        let vmChannel = try await ClientBootstrap(group: self.eventLoopGroup)
          .channelOption(.allowRemoteHalfClosure, value: true)
          .withConnectedSocket(vsockHandle.fileDescriptor) { childChannel in
            childChannel.eventLoop.makeCompletedFuture {
              try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: childChannel,
                configuration: portForwardHalfCloseConfig
              )
            }
          }

        // Write 2-byte big-endian target port header before proxying data.
        // Use NIO writeAndFlush to guarantee full delivery.
        try await vmChannel.executeThenClose { vmInbound, vmOutbound in
          var header = ByteBuffer()
          header.writeInteger(guestPort, endianness: .big)
          try await vmOutbound.write(header)

          // Bidirectional proxy with half-close propagation.
          // When one direction hits EOF, finish() the opposite writer to signal
          // EOF per-direction rather than tearing down the whole connection.
          try await withThrowingDiscardingTaskGroup { group in
            // client → vm
            group.addTask {
              for try await message in clientInbound {
                try await vmOutbound.write(message)
              }
              vmOutbound.finish()
              DVMLog.log(level: "debug", "port-fwd[\(connId)]: client→vm EOF")
            }

            // vm → client
            group.addTask {
              for try await message in vmInbound {
                try await clientOutbound.write(message)
              }
              clientOutbound.finish()
              DVMLog.log(level: "debug", "port-fwd[\(connId)]: vm→client EOF")
            }
          }
        }

        // Prevent vsockHandle from being optimized away before session ends
        withExtendedLifetime(vsockHandle) {
          // Keep the vsock handle alive until the proxy session finishes.
        }
        DVMLog.log(level: "debug", "port-fwd[\(connId)]: session complete")
      }
    } catch {
      DVMLog.log(level: "warn", "port-fwd[\(connId)]: \(guestPort) failed: \(error)")
    }
  }
}
