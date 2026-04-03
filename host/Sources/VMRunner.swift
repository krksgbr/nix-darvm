import Foundation
import Virtualization

/// Manages VM lifecycle: boot, wait, stop.
/// Reference: Lume's BaseVirtualizationService (MIT).
@MainActor
final class VMRunner {
    let vm: VZVirtualMachine
    let macAddress: VZMACAddress

    init(_ configured: ConfiguredVM) {
        self.vm = configured.vm
        self.macAddress = configured.macAddress
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success:
                    cont.resume()
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vm.stop { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    func requestStop() throws {
        try vm.requestStop()
    }

    /// Wait for the VM to stop. Returns when the VM reaches the stopped state.
    func waitUntilStopped() async {
        while vm.state != .stopped && vm.state != .error {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
    }

    /// Resolve the guest IP via DHCP lease lookup (fallback for IP display).
    func resolveIP() -> GuestIP? {
        DHCPLeaseParser.getIPAddress(forMAC: macAddress.string)
    }
}

enum RunnerError: Error, CustomStringConvertible {
    case vmNotRunning

    var description: String {
        switch self {
        case .vmNotRunning: return "VM is not running"
        }
    }
}
