import Foundation
import NIOCore
import NIOPosix
@preconcurrency import Virtualization

/// Proxies connections from a Unix domain socket to a VM's vsock device.
///
/// gRPC clients connect to `/tmp/darvm-agent.sock`. Each connection is forwarded
/// to the guest agent's gRPC server on vsock port 6175 via
/// `VZVirtioSocketDevice.connect(toPort:)`.
///
/// IMPORTANT: The `VZVirtioSocketConnection` must be retained for the full
/// session duration. Deallocation tears down the vsock channel immediately.
@MainActor
final class AgentProxy {
    static let defaultPath = "/tmp/darvm-agent.sock"
    static let defaultPort: UInt32 = 6175

    let socketPath: String
    let vmPort: UInt32
    let socketDevice: VZVirtioSocketDevice
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var serverTask: Task<Void, Error>?

    init(
        vm: VZVirtualMachine,
        socketPath: String = defaultPath,
        vmPort: UInt32 = defaultPort
    ) throws {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw BridgeError.noSocketDevice
        }
        self.socketDevice = device
        self.socketPath = socketPath
        self.vmPort = vmPort
    }

    func start() {
        serverTask = Task {
            try await run()
        }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
        cleanup()
    }

    func cleanup() {
        unlink(socketPath)
    }

    /// Holds a vsock connection and its raw fd together.
    /// The connection object MUST be retained for the session duration —
    /// VZVirtioSocketConnection tears down the channel on dealloc.
    struct VsockHandle: @unchecked Sendable {
        let connection: VZVirtioSocketConnection
        let fileDescriptor: Int32
    }

    /// Connect to the VM vsock device.
    /// Must be called on MainActor since VZVirtioSocketDevice requires it.
    func connectToVM() async throws -> VsockHandle {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<VsockHandle, Error>) in
            socketDevice.connect(toPort: vmPort) { result in
                switch result {
                case .success(let conn):
                    cont.resume(returning: VsockHandle(
                        connection: conn,
                        fileDescriptor: conn.fileDescriptor
                    ))
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func run() async throws {
        unlink(socketPath)

        let serverChannel = try await ServerBootstrap(group: eventLoopGroup)
            .bind(unixDomainSocketPath: socketPath) { childChannel in
                childChannel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: childChannel
                    )
                }
            }

        DVMLog.log(phase: nil, "agent proxy listening on \(socketPath)")

        try await withThrowingDiscardingTaskGroup { group in
            try await serverChannel.executeThenClose { serverInbound in
                for try await clientChannel in serverInbound {
                    group.addTask {
                        await self.handleClient(clientChannel)
                    }
                }
            }
        }
    }

    nonisolated private func handleClient(_ clientChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        let connId = UInt32.random(in: 0...0xFFFF)

        do {
            try await clientChannel.executeThenClose { clientInbound, clientOutbound in
                DVMLog.log(level: "debug", "proxy[\(connId)]: client connected, dialing vsock port \(self.vmPort)")

                // Connect to VM vsock — retain the handle for the entire session
                let vsockHandle = try await self.connectToVM()
                DVMLog.log(level: "debug", "proxy[\(connId)]: vsock connected (fd=\(vsockHandle.fileDescriptor))")

                let vmChannel = try await ClientBootstrap(group: self.eventLoopGroup)
                    .withConnectedSocket(vsockHandle.fileDescriptor) { childChannel in
                        childChannel.eventLoop.makeCompletedFuture {
                            try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                                wrappingChannelSynchronously: childChannel
                            )
                        }
                    }

                // Keep vsockHandle alive for the full proxy session.
                // NIO owns the fd now but VZVirtioSocketConnection dealloc
                // would tear down the underlying vsock transport.
                try await vmChannel.executeThenClose { vmInbound, vmOutbound in
                    try await withThrowingDiscardingTaskGroup { group in
                        group.addTask {
                            for try await message in clientInbound {
                                try await vmOutbound.write(message)
                            }
                            DVMLog.log(level: "debug", "proxy[\(connId)]: client→vm EOF")
                        }

                        group.addTask {
                            for try await message in vmInbound {
                                try await clientOutbound.write(message)
                            }
                            DVMLog.log(level: "debug", "proxy[\(connId)]: vm→client EOF")
                        }
                    }
                }

                // Prevent vsockHandle from being optimized away before session ends
                withExtendedLifetime(vsockHandle) {}
                DVMLog.log(level: "debug", "proxy[\(connId)]: session complete")
            }
        } catch {
            DVMLog.log(level: "warn", "proxy[\(connId)]: failed: \(error)")
        }
    }
}
