import ArgumentParser
import Foundation
import Virtualization

@MainActor
extension Start {
  func restartGuestBridgeAndInstallCA(
    agentClient: AgentClient,
    caCertPEM: String
  ) async throws {
    tprint("Restarting nix daemon bridge...")
    _ = try await agentClient.exec(command: ["sudo", "launchctl", "bootout", "system/com.darvm.agent-bridge"])
    _ = try await agentClient.exec(
      command: [
        "sudo", "launchctl", "bootstrap", "system",
        "/Library/LaunchDaemons/com.darvm.agent-bridge.plist"
      ]
    )
    try await installGuestCA(agentClient: agentClient, caCertPEM: caCertPEM)
  }

  func installGuestCA(
    agentClient: AgentClient,
    caCertPEM: String
  ) async throws {
    guard !caCertPEM.isEmpty else {
      return
    }
    let certScript = """
      printf '%s' \(shellQuote(caCertPEM)) > /tmp/dvm-ca.pem && \
      security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/dvm-ca.pem && \
      rm -f /tmp/dvm-ca.pem
      """
    let caInstallCode = try await agentClient.exec(command: ["sudo", "sh", "-c", certScript])
    if caInstallCode != 0 {
      DVMLog.log(level: "warn", "failed to install MITM CA in guest trust store")
      tprint("Warning: failed to install CA cert in guest. HTTPS interception may not work.")
    } else {
      DVMLog.log(phase: .activating, "installed MITM CA in guest trust store")
      tprint("MITM CA installed in guest trust store.")
    }
    let nodeCAScript = """
      printf '%s' \(shellQuote(caCertPEM)) > /etc/dvm-ca.pem && \
      chmod 644 /etc/dvm-ca.pem
      """
    _ = try await agentClient.exec(command: ["sudo", "sh", "-c", nodeCAScript])
    DVMLog.log(phase: .activating, "wrote CA cert to /etc/dvm-ca.pem for NODE_EXTRA_CA_CERTS")
  }

  func registerRuntimeHandlers(
    controlSocket: ControlSocket,
    services: StartedGuestServices,
    netstackSupervisor: NetstackSupervisor,
    effectiveMounts: [MountConfig]
  ) {
    controlSocket.loadCredentialsHandler = { [netstackSupervisor] projectName, secretDicts in
      do {
        let secrets = try decodeResolvedSecrets(secretDicts)
        try netstackSupervisor.loadCredentials(projectName: projectName, secrets: secrets)
        return nil
      } catch {
        return "\(error)"
      }
    }
    let agentClient = services.agentClient
    let portForwarder = services.portForwarder
    controlSocket.guestHealthHandler = { [agentClient, portForwarder] in
      final class Box: @unchecked Sendable { var value: GuestHealthPayload? }
      let box = Box()
      let semaphore = DispatchSemaphore(value: 0)
      Task { @MainActor in
        defer { semaphore.signal() }
        if let status = try? await agentClient.status() {
          box.value = GuestHealthPayload(
            builtInMounts: effectiveMounts.filter(\.isBuiltIn).map(\.formatDescription),
            mounts: effectiveMounts.filter { !$0.isBuiltIn }.map(\.formatDescription),
            activation: status.activation,
            services: status.services.reduce(into: [:]) { $0[$1.key] = $1.value },
            forwardedPorts: portForwarder?.publishedPorts.sorted() ?? [],
            portConflicts: portForwarder?.conflicts.sorted() ?? []
          )
        }
      }
      guard semaphore.wait(timeout: .now() + 5) == .success else {
        return nil
      }
      return box.value
    }
  }

  nonisolated func decodeResolvedSecrets(_ secretDicts: [[String: Any]]) throws -> [ResolvedSecret] {
    try secretDicts.enumerated().map { index, dict in
      guard let name = dict["name"] as? String,
        let placeholder = dict["placeholder"] as? String,
        let value = dict["value"] as? String,
        let hosts = dict["hosts"] as? [String]
      else {
        throw DVMError.activationFailed(
          "loadCredentials: secret at index \(index) has missing or invalid fields"
        )
      }
      return ResolvedSecret(
        name: name,
        mode: .proxy,
        placeholder: placeholder,
        value: value,
        hosts: hosts
      )
    }
  }

  func finishRunningSession(
    guestIP: GuestIP,
    controlSocket: ControlSocket,
    services: StartedGuestServices,
    netstackSupervisor: NetstackSupervisor,
    runner: VMRunner
  ) async {
    controlSocket.update(.running, guestIP: guestIP)
    DVMLog.log(phase: .running, "VM running at \(guestIP)")
    tprint("VM running. Press Ctrl-C to stop.")
    await runner.waitUntilStopped()
    controlSocket.update(.stopped)
    DVMLog.log(phase: .stopped, "VM stopped")
    DVMLog.log(phase: .stopped, "shutting down dvm-netstack")
    netstackSupervisor.shutdown()
    controlSocket.cleanup()
    services.agentProxy.cleanup()
    if let reconciler = services.portForwardReconciler {
      await reconciler.stop()
    } else {
      await services.portForwarder?.stop()
    }
    tprint("VM stopped.")
  }

  func removeManagedExports(_ manager: NFSExportManager?) {
    do {
      try manager?.removeManagedExports()
    } catch {
      DVMLog.log(level: "error", "failed to remove DVM NFS exports: \(error)")
    }
  }
}
