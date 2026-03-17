import Foundation
@preconcurrency import Virtualization

/// Listens on a vsock port for guest command-forwarding requests.
///
/// When a guest process (dvm-host-cmd) connects, it sends a NUL-separated
/// command + args terminated by a newline, then shuts down the write end.
/// The bridge checks the command against an allowlist, executes it on the host,
/// and returns the exit code.
///
/// Security notes:
/// - The allowlist is the primary security boundary. It is currently loaded from
///   ~/.config/dvm/config.toml — WARNING: this file must NOT be mounted writable
///   in the guest, or a rogue process can escalate to arbitrary host execution.
///   TODO: migrate allowlist to nix config (nix-darvm-xuus).
/// - Any process in the guest can connect to this port (vsock has no caller auth).
/// - Args are unconstrained — the guest can pass any flags the allowed binary accepts.
///
/// Protocol:
///   Request:  cmd\x00arg1\x00arg2\n  (guest shuts down write after sending)
///   Response: 0\n                     (exit code, or code\x00error\n on failure)
@MainActor
final class HostCommandBridge {
    static let defaultPort: UInt32 = 6176

    let socketDevice: VZVirtioSocketDevice
    let listenPort: UInt32
    let allowedCommands: Set<String>

    private var listenerDelegate: ListenerDelegate?

    init(
        vm: VZVirtualMachine,
        allowedCommands: Set<String>,
        listenPort: UInt32 = defaultPort
    ) throws {
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw BridgeError.noSocketDevice
        }
        self.socketDevice = device
        self.listenPort = listenPort
        self.allowedCommands = allowedCommands
    }

    func start() {
        let listener = VZVirtioSocketListener()
        let delegate = ListenerDelegate(bridge: self)
        self.listenerDelegate = delegate
        listener.delegate = delegate
        socketDevice.setSocketListener(listener, forPort: listenPort)
        DVMLog.log("host command bridge listening on vsock port \(listenPort) (commands: \(allowedCommands.sorted().joined(separator: ", ")))")
    }

    /// Handle a guest connection. Runs on a background thread.
    /// The connection object must stay alive for the duration.
    nonisolated func handleConnection(_ connection: VZVirtioSocketConnection) {
        let fd = connection.fileDescriptor

        // Read request until EOF or 64KB limit
        let maxBytes = 65536
        var data = Data()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        defer { buf.deallocate() }

        while data.count < maxBytes {
            let n = read(fd, buf, min(4096, maxBytes - data.count))
            if n <= 0 { break }
            data.append(buf.assumingMemoryBound(to: UInt8.self), count: n)
        }

        guard !data.isEmpty else {
            writeResponse(fd: fd, code: 1, error: "empty request")
            return
        }

        // Parse: strip trailing newline, split on NUL
        guard var request = String(data: data, encoding: .utf8) else {
            writeResponse(fd: fd, code: 1, error: "invalid UTF-8")
            return
        }
        while request.hasSuffix("\n") {
            request.removeLast()
        }

        let parts = request.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard let command = parts.first, !command.isEmpty else {
            writeResponse(fd: fd, code: 1, error: "empty command")
            return
        }
        let args = Array(parts.dropFirst())

        // Allowlist check
        guard allowedCommands.contains(command) else {
            DVMLog.log(level: "warn", "host command blocked: \(command)")
            writeResponse(fd: fd, code: 1, error: "command not allowed: \(command)")
            return
        }

        DVMLog.log(level: "debug", "host command: \(command) \(args.joined(separator: " "))")

        // Execute via /usr/bin/env (resolves via host PATH)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args

        // Capture stderr for error reporting
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Pipe stdin from the request (hooks may pipe data via stdin)
        process.standardInput = FileHandle.nullDevice

        // 10s timeout
        let timeoutItem = DispatchWorkItem { [weak process] in
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)

        do {
            try process.run()
            process.waitUntilExit()
            timeoutItem.cancel()

            let exitCode = process.terminationStatus
            if exitCode != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !stderrStr.isEmpty {
                    writeResponse(fd: fd, code: exitCode, error: stderrStr)
                } else {
                    writeResponse(fd: fd, code: exitCode, error: nil)
                }
            } else {
                writeResponse(fd: fd, code: 0, error: nil)
            }
        } catch {
            timeoutItem.cancel()
            DVMLog.log(level: "error", "host command exec failed: \(error)")
            writeResponse(fd: fd, code: 1, error: "exec failed: \(error)")
        }
    }

    private nonisolated func writeResponse(fd: Int32, code: Int32, error: String?) {
        let response: String
        if let error, !error.isEmpty {
            response = "\(code)\0\(error)\n"
        } else {
            response = "\(code)\n"
        }
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress!, ptr.count)
        }
    }
}

// MARK: - VZVirtioSocketListenerDelegate

extension HostCommandBridge {
    final class ListenerDelegate: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
        let bridge: HostCommandBridge

        init(bridge: HostCommandBridge) {
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
