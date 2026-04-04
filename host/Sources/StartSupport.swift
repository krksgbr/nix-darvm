import ArgumentParser
import Foundation
import Virtualization

private struct PreparedStartContext {
    let controlSocket: ControlSocket
    let vmDirectory: URL
    let mounts: [MountConfig]
    let netstackSupervisor: NetstackSupervisor
    let stateDir: URL
    let homeDataDir: URL
    let netstackBinary: String
}

private struct ConfiguredStartContext {
    let runner: VMRunner
    let effectiveMounts: [MountConfig]
    let nfsMACAddress: VZMACAddress?
    let caCertPEM: String
}

private struct StartedGuestServices {
    let vsockBridge: VsockDaemonBridge
    let agentProxy: AgentProxy
    let agentClient: AgentClient
    let hostCommandBridgeBox: HostCommandBridgeBox
}

private struct SignalSources {
    let sigintSource: DispatchSourceSignal
    let sigtermSource: DispatchSourceSignal
}

private struct BootErrorMonitor {
    let bootErrorFile: URL

    init(stateDir: URL) {
        bootErrorFile = stateDir.appendingPathComponent("boot-error")
    }

    func currentError() -> String? {
        guard
            let error = try? String(contentsOf: bootErrorFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !error.isEmpty
        else { return nil }
        return error
    }
}

private final class HostCommandBridgeBox: @unchecked Sendable {
    var bridge: HostCommandBridge?
}

private enum ActivationPollResult {
    case pending
    case succeeded
    case failed
}

private struct RuntimeMountPreparation {
    let nfsMirrorMounts: [MountConfig]
    let nfsHostIP: GuestIP?
    let nfsExportManager: NFSExportManager?
}

private struct RunningStartContext {
    let signalSources: SignalSources
    let services: StartedGuestServices
    let guestIP: GuestIP
    let nfsExportManager: NFSExportManager?
}
