import ArgumentParser
import Foundation
import Virtualization

struct PreparedStartContext {
  let controlSocket: ControlSocket
  let vmDirectory: URL
  let mounts: [MountConfig]
  let netstackSupervisor: NetstackSupervisor
  let stateDir: URL
  let homeDataDir: URL
  let netstackBinary: String
}

struct ConfiguredStartContext {
  let runner: VMRunner
  let effectiveMounts: [MountConfig]
  let nfsMACAddress: VZMACAddress?
  let caCertPEM: String
}

struct StartedGuestServices {
  let vsockBridge: VsockDaemonBridge
  let agentProxy: AgentProxy
  let agentClient: AgentClient
  let hostCommandBridgeBox: HostCommandBridgeBox
  var portForwarder: PortForwarder?
}

struct SignalSources {
  let sigintSource: DispatchSourceSignal
  let sigtermSource: DispatchSourceSignal
}

struct BootErrorMonitor {
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

final class HostCommandBridgeBox: @unchecked Sendable {
  var bridge: HostCommandBridge?
}

enum ActivationPollResult {
  case pending
  case succeeded
  case failed
}

enum GuestAgentPollResult {
  case ready
  case unreachable
  case portForwardNotReady
}

struct RuntimeMountPreparation {
  let nfsMirrorMounts: [MountConfig]
  let nfsHostIP: GuestIP?
  let nfsExportManager: NFSExportManager?
}

struct RunningStartContext {
  let signalSources: SignalSources
  let services: StartedGuestServices
  let guestIP: GuestIP
  let nfsExportManager: NFSExportManager?
}

func expandTilde(in path: String) -> String {
  guard path == "~" || path.hasPrefix("~/") else {
    return path
  }

  let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
  guard path.count > 1 else {
    return homeDirectory
  }

  return homeDirectory + path.dropFirst(1)
}
