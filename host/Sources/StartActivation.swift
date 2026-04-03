import ArgumentParser
import Foundation
import Virtualization

extension Start {
  fileprivate func waitForActivationIfNeeded(
    stateDir: URL,
    runner: VMRunner,
    bootErrorMonitor: BootErrorMonitor,
    controlSocket: ControlSocket
  ) async throws {
    guard systemClosure != nil else {
      return
    }
    controlSocket.update(.activating)
    DVMLog.log(phase: .activating, "waiting for guest activation via state files")
    tprint("Waiting for guest activation...")

    let runDir = stateDir.appendingPathComponent(DVMLog.runId)
    let statusFile = runDir.appendingPathComponent("status")
    let logFile = stateDir.appendingPathComponent("run.log")
    let deadline = Date().addingTimeInterval(300)
    var logOffset = 0
    var logLineBuffer = ""
    var activatorStarted = false

    while Date() < deadline, !stopRequested {
      try await checkActivationBootError(bootErrorMonitor: bootErrorMonitor, runner: runner)
      drainActivationLog(logFile: logFile, logOffset: &logOffset, logLineBuffer: &logLineBuffer)
      let result = processActivationStatus(
        statusFile: statusFile,
        runDir: runDir,
        logLineBuffer: &logLineBuffer,
        activatorStarted: &activatorStarted
      )
      if result != .pending {
        return
      }
      try? await Task.sleep(nanoseconds: 500_000_000)
    }
    if !stopRequested, Date() >= deadline {
      DVMLog.log(phase: .activating, level: "error", "activation timed out after 5 min")
      tprint("Warning: activation did not complete within 5 minutes.")
    }
  }

  fileprivate func checkActivationBootError(
    bootErrorMonitor: BootErrorMonitor,
    runner: VMRunner
  ) async throws {
    guard let bootError = bootErrorMonitor.currentError() else {
      return
    }
    DVMLog.log(phase: .activating, level: "error", "guest boot failed: \(bootError)")
    tprint("FATAL: Guest boot failed: \(bootError)")
    try? await runner.stop()
    throw DVMError.activationFailed("guest boot failed: \(bootError)")
  }

  fileprivate func drainActivationLog(
    logFile: URL,
    logOffset: inout Int,
    logLineBuffer: inout String
  ) {
    guard let data = try? Data(contentsOf: logFile), data.count > logOffset else {
      return
    }
    let newData = data.subdata(in: logOffset..<data.count)
    logOffset = data.count
    guard let text = String(data: newData, encoding: .utf8) else {
      return
    }
    logLineBuffer += text
    var lines = logLineBuffer.components(separatedBy: "\n")
    logLineBuffer = lines.removeLast()
    for line in lines where !line.isEmpty {
      tprint(line)
    }
  }

  fileprivate func processActivationStatus(
    statusFile: URL,
    runDir: URL,
    logLineBuffer: inout String,
    activatorStarted: inout Bool
  ) -> ActivationPollResult {
    guard
      let statusText = try? String(contentsOf: statusFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return .pending
    }
    if statusText == "running", !activatorStarted {
      activatorStarted = true
      DVMLog.log(phase: .activating, "activator running")
    }
    if statusText == "done" {
      flushActivationLogBuffer(&logLineBuffer)
      DVMLog.log(phase: .activating, "activation succeeded")
      tprint("Activation succeeded.")
      return .succeeded
    }
    guard statusText == "failed" || statusText == "invalid-closure" else {
      return .pending
    }
    flushActivationLogBuffer(&logLineBuffer)
    let exitCode = activationExitCode(runDir: runDir)
    DVMLog.log(
      phase: .activating,
      level: "error",
      "activation failed (status=\(statusText), exit=\(exitCode))"
    )
    tprint("Activation failed (exit code \(exitCode)).")
    return .failed
  }

  fileprivate func flushActivationLogBuffer(_ logLineBuffer: inout String) {
    guard !logLineBuffer.isEmpty else {
      return
    }
    tprint(logLineBuffer)
    logLineBuffer = ""
  }

  fileprivate func activationExitCode(runDir: URL) -> String {
    (try? String(
      contentsOf: runDir.appendingPathComponent("exit-code"),
      encoding: .utf8
    ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
  }

  fileprivate func waitForGuestAgent(
    services: StartedGuestServices,
    runner: VMRunner,
    controlSocket: ControlSocket,
    bootErrorMonitor: BootErrorMonitor
  ) async throws {
    controlSocket.update(.waitingForAgent)
    DVMLog.log(phase: .waitingForAgent, "waiting for guest agent")
    tprint("Waiting for guest agent...")

    guard await pollForGuestAgent(services: services, bootErrorMonitor: bootErrorMonitor) else {
      if stopRequested {
        return
      }
      controlSocket.update(.failed, error: "guest agent unreachable")
      tprint("Stopping VM.")
      try? await runner.stop()
      controlSocket.cleanup()
      services.agentProxy.cleanup()
      throw DVMError.activationFailed("guest agent unreachable")
    }

    DVMLog.log(phase: .waitingForAgent, "agent is reachable")
    tprint("Guest agent connected.")
    await logGuestNetworkSnapshot(agentClient: services.agentClient)
  }

  fileprivate func pollForGuestAgent(
    services: StartedGuestServices,
    bootErrorMonitor: BootErrorMonitor
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline, !stopRequested {
      if let bootError = bootErrorMonitor.currentError() {
        DVMLog.log(phase: .waitingForAgent, level: "error", "guest boot failed: \(bootError)")
        tprint("FATAL: Guest boot failed: \(bootError)")
        return false
      }
      if (try? await services.agentClient.status()) != nil {
        return true
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return false
  }

  fileprivate func logGuestNetworkSnapshot(agentClient: AgentClient) async {
    if let networkSnapshot = try? await agentClient.execCaptureOutput(
      command: ["sh", "-c", "ifconfig -a; printf '\\n--- ROUTES ---\\n'; netstat -rn -f inet"]
    ), !networkSnapshot.isEmpty {
      DVMLog.log(phase: .waitingForAgent, "guest network snapshot:\n\(networkSnapshot)")
      return
    }
    DVMLog.log(
      phase: .waitingForAgent,
      level: "warn",
      "failed to capture guest network snapshot"
    )
  }

  fileprivate func resolveGuestIP(
    services: StartedGuestServices,
    runner: VMRunner,
    controlSocket: ControlSocket
  ) async throws -> GuestIP {
    do {
      let guestIP = try await services.agentClient.resolveIP()
      tprint("VM reachable at \(guestIP)")
      DVMLog.log(phase: .waitingForAgent, "guest IP: \(guestIP)")
      return guestIP
    } catch {
      return try await resolveFallbackGuestIP(error: error, runner: runner, controlSocket: controlSocket)
    }
  }

  fileprivate func resolveFallbackGuestIP(
    error: Error,
    runner: VMRunner,
    controlSocket: ControlSocket
  ) async throws -> GuestIP {
    if let dhcpIP = runner.resolveIP() {
      tprint("VM reachable at \(dhcpIP) (DHCP fallback)")
      return dhcpIP
    }
    let message = "Could not resolve guest IP: \(error)"
    controlSocket.update(.failed, error: message)
    DVMLog.log(phase: .failed, level: "error", message)
    tprint("Warning: \(message)")
    tprint("VM running. Press Ctrl-C to stop.")
    await runner.waitUntilStopped()
    controlSocket.cleanup()
    tprint("VM stopped.")
    throw DVMError.activationFailed(message)
  }
}
