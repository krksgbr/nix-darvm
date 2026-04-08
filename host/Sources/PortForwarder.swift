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
/// Supports dynamic publish/unpublish of individual ports at runtime.
/// When a client connects to a published port, we dial vsock 6177,
/// write a 2-byte big-endian target port header, then proxy bidirectionally.
///
/// IMPORTANT: The `VZVirtioSocketConnection` must be retained for the full
/// session duration. Deallocation tears down the vsock channel immediately.
@MainActor
final class PortForwarder {
  static let vsockPort: UInt32 = 6_177

  /// Holds a vsock connection and its raw fd together.
  /// The connection object MUST be retained for the session duration —
  /// VZVirtioSocketConnection tears down the channel on dealloc.
  struct VsockHandle: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
    let fileDescriptor: Int32
  }

  /// Tracks listeners for a single published port.
  /// We bind both IPv4 (127.0.0.1) and IPv6 (::1) loopback to fully claim
  /// the port and prevent host processes from shadowing the guest service.
  private struct ActiveListener {
    let channels: [NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>]
    let tasks: [Task<Void, Never>]
    let port: UInt16
  }

  let socketDevice: VZVirtioSocketDevice
  private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

  /// Currently published port listeners.
  private var activeListeners: [UInt16: ActiveListener] = [:]

  /// Ports where the most recent bind attempt failed (host conflict).
  /// Cleared when a port is successfully published.
  private(set) var conflicts: Set<UInt16> = []

  /// The set of currently forwarded host ports.
  var publishedPorts: Set<UInt16> {
    Set(activeListeners.keys)
  }

  init(virtualMachine: VZVirtualMachine) throws {
    guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
      throw BridgeError.noSocketDevice
    }
    self.socketDevice = device
  }

  // MARK: - Dynamic publish/unpublish

  /// Bind a single host port and start an accept loop forwarding to the
  /// same port in the guest.
  ///
  /// Returns true if the port was newly published. Returns false if already
  /// active or if the bind failed (conflict). Bind failures are recorded in
  /// `conflicts` and logged.
  /// Addresses to bind for each published port.
  /// Both IPv4 and IPv6 loopback so that host processes cannot shadow the
  /// guest service by binding on the other address family.
  private static let bindAddresses = ["127.0.0.1", "::1"]

  @discardableResult
  func publish(port: UInt16) async -> Bool {
    guard activeListeners[port] == nil else {
      return false
    }

    var channels: [NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>] = []

    do {
      for host in Self.bindAddresses {
        let serverChannel = try await ServerBootstrap(group: eventLoopGroup)
          .bind(host: host, port: Int(port)) { childChannel in
            childChannel.eventLoop.makeCompletedFuture {
              try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: childChannel,
                configuration: portForwardHalfCloseConfig
              )
            }
          }
        channels.append(serverChannel)
      }
    } catch {
      // Roll back any channels that did bind.
      for channel in channels {
        try? await channel.channel.close()
      }
      let isNew = conflicts.insert(port).inserted
      DVMLog.log(level: "warn", "port forward: publish localhost:\(port) failed: \(error)")
      if isNew {
        tprint("Port conflict: localhost:\(port) — host port already in use")
      }
      return false
    }

    let tasks = channels.map { channel in
      Task {
        do {
          try await self.runAcceptLoop(serverChannel: channel, guestPort: port)
        } catch is CancellationError {
          // normal cancellation on unpublish/stop
        } catch {
          DVMLog.log(level: "warn", "port-fwd: accept loop closed for port \(port): \(error)")
        }
      }
    }

    activeListeners[port] = ActiveListener(channels: channels, tasks: tasks, port: port)
    let recovered = conflicts.remove(port) != nil
    DVMLog.log("port forward: published localhost:\(port)")
    if recovered {
      tprint("Port forwarding recovered: localhost:\(port) → guest:\(port)")
    } else {
      tprint("Port forwarding: localhost:\(port) → guest:\(port)")
    }
    return true
  }

  /// Stop forwarding a single port. Idempotent.
  func unpublish(port: UInt16) async {
    guard let listener = activeListeners.removeValue(forKey: port) else {
      return
    }
    for task in listener.tasks {
      task.cancel()
    }
    for channel in listener.channels {
      try? await channel.channel.close()
    }
    DVMLog.log("port forward: unpublished localhost:\(port)")
    tprint("Port forwarding stopped: localhost:\(port)")
  }

  /// Stop all published ports and shut down the event loop group.
  func stop() async {
    for port in Array(activeListeners.keys) {
      await unpublish(port: port)
    }
    try? await eventLoopGroup.shutdownGracefully()
  }

  // MARK: - Vsock connection

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

  // MARK: - Accept loop and client handling

  private func runAcceptLoop(
    serverChannel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>,
    guestPort: UInt16
  ) async throws {
    try await withThrowingDiscardingTaskGroup { group in
      try await serverChannel.executeThenClose { serverInbound in
        for try await clientChannel in serverInbound {
          group.addTask {
            await self.handleClient(clientChannel, guestPort: guestPort)
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
