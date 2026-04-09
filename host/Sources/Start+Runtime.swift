import ArgumentParser
import Foundation
import Virtualization

@MainActor
extension Start {
  func performBootSequence(
    services: inout StartedGuestServices,
    bootErrorMonitor: BootErrorMonitor,
    portPolicy: PortPolicy,
    prepared: PreparedStartContext,
    configured: ConfiguredStartContext
  ) async throws {
    try await waitForActivationIfNeeded(
      stateDir: prepared.stateDir,
      runner: configured.runner,
      bootErrorMonitor: bootErrorMonitor,
      controlSocket: prepared.controlSocket
    )
    try await waitForGuestAgent(
      services: services,
      runner: configured.runner,
      controlSocket: prepared.controlSocket,
      bootErrorMonitor: bootErrorMonitor,
      stateDir: prepared.stateDir,
      requirePortForwardReady: portPolicy.autoForward
    )
    if portPolicy.autoForward {
      let forwarder = try PortForwarder(virtualMachine: configured.runner.virtualMachine)
      let reconciler = PortForwardReconciler(portForwarder: forwarder, policy: portPolicy)
      reconciler.start()
      services.portForwarder = forwarder
      services.portForwardReconciler = reconciler
      tprint("Auto port forwarding enabled.")
    }
  }

  func mountRuntimeShares(
    services: StartedGuestServices,
    effectiveMounts: [MountConfig],
    homeLinks: [HomeLink],
    nfsMACAddress: VZMACAddress?
  ) async throws -> NFSExportManager? {
    let remainingMounts = effectiveMounts.filter { $0.tag.rawValue != "nix-store" }
    let preparation = try await prepareRuntimeMounts(
      remainingMounts: remainingMounts,
      nfsMACAddress: nfsMACAddress
    )
    DVMLog.log(
      phase: .mounting,
      "mounting \(remainingMounts.count) runtime shares (nix-store handled by image)"
    )
    tprint("Mounting runtime shares...")

    let scriptBody = try makeRuntimeMountScript(
      remainingMounts: remainingMounts,
      nfsHostIP: preparation.nfsHostIP
    )
    let mountExitCode = try await services.agentClient.exec(command: ["sudo", "sh", "-c", scriptBody])
    try await logRuntimeMountDiagnostics(
      agentClient: services.agentClient,
      hasNFSMirrorMounts: !preparation.nfsMirrorMounts.isEmpty
    )
    if mountExitCode != 0 {
      DVMLog.log(phase: .mounting, level: "error", "one or more runtime mounts failed")
      tprint("ERROR: One or more runtime mounts failed.")
      throw DVMError.setupFailed("one or more runtime mounts failed (see mount logs above)")
    }
    DVMLog.log(phase: .mounting, "all mounts succeeded")

    // Install HomeLinks: symlinks from ~/subpath to their targets.
    // Runs after mounts so that mount-backed targets are ready.
    if !homeLinks.isEmpty {
      DVMLog.log(phase: .mounting, "installing \(homeLinks.count) home links")
      tprint("Installing home links...")
      let homeLinkScript = makeHomeLinkInstallScript(
        homeLinks: homeLinks,
        guestHome: guestHome
      )
      let linkExitCode = try await services.agentClient.exec(
        command: ["sudo", "sh", "-c", homeLinkScript]
      )
      if linkExitCode != 0 {
        DVMLog.log(phase: .mounting, level: "error", "one or more home links failed")
        tprint("ERROR: One or more home links failed to install.")
        throw DVMError.setupFailed("one or more home links failed to install (see mount logs above)")
      }
      DVMLog.log(phase: .mounting, "all home links installed")
    }

    return preparation.nfsExportManager
  }

  func prepareRuntimeMounts(
    remainingMounts: [MountConfig],
    nfsMACAddress: VZMACAddress?
  ) async throws -> RuntimeMountPreparation {
    let nfsMirrorMounts = remainingMounts.filter { $0.transport == .nfs && $0.isMirror }
    guard !nfsMirrorMounts.isEmpty else {
      return RuntimeMountPreparation(nfsMirrorMounts: [], nfsHostIP: nil, nfsExportManager: nil)
    }
    guard let nfsMACAddress else {
      fatalError("NFS mirror mounts exist but no NFS network MAC was configured")
    }
    DVMLog.log(phase: .mounting, "waiting for NFS NIC DHCP lease (mac=\(nfsMACAddress.string))")
    let nfsGuestIP = try await waitForNFSGuestIP(macAddress: nfsMACAddress)
    let hostResolution = try HostNetworkResolver.resolve(reachableFrom: nfsGuestIP)
    let manager = NFSExportManager(guestIP: nfsGuestIP)
    try manager.install(for: nfsMirrorMounts)
    DVMLog.log(
      phase: .mounting,
      "configuring NFS exports for \(nfsMirrorMounts.count) mirror mounts "
        + "(guest=\(nfsGuestIP), host=\(hostResolution.hostIP), mac=\(nfsMACAddress.string), \(hostResolution))"
    )
    return RuntimeMountPreparation(
      nfsMirrorMounts: nfsMirrorMounts,
      nfsHostIP: hostResolution.hostIP,
      nfsExportManager: manager
    )
  }

  func waitForNFSGuestIP(macAddress: VZMACAddress) async throws -> GuestIP {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if let leaseIP = DHCPLeaseParser.getIPAddress(forMAC: macAddress.string) {
        return leaseIP
      }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    throw DVMError.activationFailed(
      "timed out waiting for NFS NIC DHCP lease for MAC \(macAddress.string)"
    )
  }

  func makeRuntimeMountScript(
    remainingMounts: [MountConfig],
    nfsHostIP: GuestIP?
  ) throws -> String {
    let dvmMountsDir = "/var/dvm-mounts"
    let manifestPath = shellQuote(dvmMountsDir + "/.manifest")
    let mountLogDir = shellQuote("/tmp/dvm-mount-logs")
    var scriptParts: [String] = [
      "mkdir -p \(shellQuote(dvmMountsDir))",
      "> \(manifestPath)",
      "rm -rf \(mountLogDir)",
      "mkdir -p \(mountLogDir)",
      "PIDS=\"\""
    ]
    for mount in remainingMounts {
      let snippet = try runtimeMountSnippet(
        mount: mount,
        dvmMountsDir: dvmMountsDir,
        manifestPath: manifestPath,
        nfsHostIP: nfsHostIP
      )
      scriptParts.append(snippet.functionBody)
      scriptParts.append(snippet.callLine)
    }
    scriptParts += ["FAIL=0", "for pid in $PIDS; do wait $pid || FAIL=1; done", "exit $FAIL"]
    return scriptParts.joined(separator: "\n")
  }

  func runtimeMountSnippet(
    mount: MountConfig,
    dvmMountsDir: String,
    manifestPath: String,
    nfsHostIP: GuestIP?
  ) throws -> (functionBody: String, callLine: String) {
    let mountPathRaw = runtimeMountPath(for: mount, dvmMountsDir: dvmMountsDir)
    let setupLines = runtimeMountSetupLines(mountPathRaw: mountPathRaw)
    let functionName = "mount_\(mount.tag.rawValue.replacingOccurrences(of: "-", with: "_"))"
    let functionBody = try makeRuntimeMountFunction(
      mount: mount,
      mountPathRaw: mountPathRaw,
      manifestPath: manifestPath,
      nfsHostIP: nfsHostIP,
      functionName: functionName
    )
    return (setupLines + "\n" + functionBody, "\(functionName) & PIDS=\"$PIDS $!\"")
  }

  func runtimeMountPath(for mount: MountConfig, dvmMountsDir: String) -> String {
    mount.guestPath.rawValue.hasPrefix(guestHome + "/")
      ? "\(dvmMountsDir)/\(mount.tag.rawValue)"
      : mount.guestPath.rawValue
  }

  func runtimeMountSetupLines(mountPathRaw: String) -> String {
    // Ensure the mount point directory exists. For home-relative mounts,
    // mountPathRaw is already redirected to /var/dvm-mounts/<tag> by
    // runtimeMountPath(). Symlinks from ~/subpath are handled separately
    // by the HomeLink system.
    let quotedPath = shellQuote(mountPathRaw)
    return "[ -L \(quotedPath) ] && rm -f \(quotedPath); mkdir -p \(quotedPath)"
  }

  func makeRuntimeMountFunction(
    mount: MountConfig,
    mountPathRaw: String,
    manifestPath: String,
    nfsHostIP: GuestIP?,
    functionName: String
  ) throws -> String {
    let mountPath = shellQuote(mountPathRaw)
    let quotedTag = shellQuote(mount.tag.rawValue)
    let transport = shellQuote(mount.transport.rawValue)
    let writeManifest =
      "printf '%s %s %s\\n' \(transport) \(quotedTag) \(mountPath) >> \(manifestPath)"
    let tagLogPath = shellQuote("/tmp/dvm-mount-logs/\(mount.tag.rawValue).log")
    let displayPrefix = shellQuote(mount.formatDescription)
    let mountDetails = try runtimeMountDetails(mount: mount, mountPath: mountPath, nfsHostIP: nfsHostIP)
    let prelude = runtimeMountFunctionPrelude(
      functionName: functionName,
      tagLogPath: tagLogPath,
      mountPathRaw: mountPathRaw,
      mount: mount,
      command: mountDetails.command
    )
    let alreadyMounted = runtimeMountAlreadyMountedBlock(
      displayPrefix: displayPrefix,
      writeManifest: writeManifest
    )
    let retryLoop = runtimeMountRetryLoop(
      expectedFS: mountDetails.expectedFS,
      command: mountDetails.command,
      displayPrefix: displayPrefix,
      writeManifest: writeManifest,
      mount: mount
    )
    return [prelude, alreadyMounted, retryLoop, "}"].joined(separator: "\n")
  }

  func runtimeMountFunctionPrelude(
    functionName: String,
    tagLogPath: String,
    mountPathRaw: String,
    mount: MountConfig,
    command: String
  ) -> String {
    let privateMountPathRaw =
      mountPathRaw.hasPrefix("/private/") ? mountPathRaw : "/private" + mountPathRaw
    return """
      \(functionName)() {
        log_mount() { printf '%s\\n' "$1" >> \(tagLogPath); }
        current_mount_line() {
          /sbin/mount | grep " on \(mountPathRaw) " | tail -n 1 || \
          /sbin/mount | grep " on \(privateMountPathRaw) " | tail -n 1
        }
        wait_for_mount_line() {
          line=""
          for _ in 1 2 3 4 5; do
            line=$(current_mount_line)
            [ -n "$line" ] && { printf '%s' "$line"; return 0; }
            sleep 0.2
          done
          return 1
        }
        log_mount "[BEGIN] \
        tag=\(mount.tag.rawValue) \
        transport=\(mount.transport.rawValue) \
        guest=\(mount.guestPath.rawValue) \
        host=\(mount.hostPath.rawValue)"
        log_mount "[CMD] \(command)"
        LINE=$(current_mount_line)
      """
  }

  func runtimeMountAlreadyMountedBlock(
    displayPrefix: String,
    writeManifest: String
  ) -> String {
    """
      if [ -n "$LINE" ]; then
        echo "  \(displayPrefix) (already mounted)"
        log_mount "[ALREADY] $LINE"
        \(writeManifest)
        return 0
      fi
    """
  }

  func runtimeMountRetryLoop(
    expectedFS: String,
    command: String,
    displayPrefix: String,
    writeManifest: String,
    mount: MountConfig
  ) -> String {
    """
      for i in 1 2 3 4 5; do
        ERR=$(\(command) 2>&1) && {
          LINE=$(wait_for_mount_line || true)
          case "$LINE" in
            *"(\(expectedFS),"*|*"(\(expectedFS))"*|*"("AppleVirtIOFS","*|\
            *"("AppleVirtIOFS")"*|*"(virtio-fs,"*|*"(virtio-fs))"*)
              echo "  \(displayPrefix)"
              log_mount "[OK] $LINE"
              \(writeManifest)
              return 0
              ;;
            *)
              log_mount "[VERIFY-FAILED] expected=\(expectedFS) actual=$LINE"
              ERR="mounted but unexpected fs type: $LINE"
              ;;
          esac
        }
        log_mount "[RETRY $i] $ERR"
        case "$ERR" in *"Resource busy"*) echo "  \(displayPrefix)"; \(writeManifest); return 0;; esac
        sleep 1
      done
      log_mount "[FAILED] tag=\(mount.tag.rawValue) error=$ERR"
      echo "  \(displayPrefix) (FAILED: $ERR)" >&2; return 1
    """
  }

  func runtimeMountDetails(
    mount: MountConfig,
    mountPath: String,
    nfsHostIP: GuestIP?
  ) throws -> (expectedFS: String, command: String) {
    switch mount.transport {
    case .virtiofs:
      return ("virtiofs", "/sbin/mount_virtiofs \(mount.tag) \(mountPath)")

    case .nfs:
      guard let nfsHostIP else {
        fatalError("NFS mount command requested without resolved NFS host IP")
      }
      let remote = shellQuote("\(nfsHostIP.rawValue):\(mount.hostPath.rawValue)")
      return ("nfs", "/sbin/mount_nfs -o actimeo=1 \(remote) \(mountPath)")
    }
  }

  func logRuntimeMountDiagnostics(
    agentClient: AgentClient,
    hasNFSMirrorMounts: Bool
  ) async throws {
    if let mountLog = try await agentClient.execCaptureOutput(
      command: [
        "sudo", "sh", "-c",
        """
        for f in /tmp/dvm-mount-logs/*.log; do [ -f "$f" ] || continue; \
        echo "=== $(basename "$f") ==="; cat "$f"; echo; done
        """
      ]
    ), !mountLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      DVMLog.log(phase: .mounting, "guest mount transcript:\n\(mountLog)")
    } else {
      DVMLog.log(phase: .mounting, level: "warn", "guest mount transcript missing or empty")
    }

    if let manifest = try await agentClient.execCaptureOutput(command: ["cat", "/var/dvm-mounts/.manifest"]),
      !manifest.isEmpty
    {
      DVMLog.log(phase: .mounting, "runtime mount manifest:\n\(manifest)")
    } else {
      DVMLog.log(phase: .mounting, level: "warn", "runtime mount manifest missing or unreadable")
    }

    guard hasNFSMirrorMounts else {
      return
    }
    if let nfsMountState = try await agentClient.execCaptureOutput(
      command: ["sh", "-c", "nfsstat -m 2>/dev/null || true"]
    ), !nfsMountState.isEmpty {
      DVMLog.log(phase: .mounting, "guest nfsstat -m:\n\(nfsMountState)")
    } else {
      DVMLog.log(phase: .mounting, level: "warn", "guest nfsstat -m empty or unavailable")
    }
  }
}
