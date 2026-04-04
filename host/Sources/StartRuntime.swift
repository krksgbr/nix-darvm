import ArgumentParser
import Foundation
import Virtualization

extension Start {
    fileprivate func mountRuntimeShares(
        services: StartedGuestServices,
        controlSocket: ControlSocket,
        effectiveMounts: [MountConfig],
        nfsMACAddress: VZMACAddress?,
        guestIP: GuestIP
    ) async throws -> NFSExportManager? {
        let remainingMounts = effectiveMounts.filter { !["nix-store", "dvm-home"].contains($0.tag.rawValue) }
        controlSocket.update(.mounting, guestIP: guestIP)
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
        } else {
            DVMLog.log(phase: .mounting, "all mounts succeeded")
        }
        return preparation.nfsExportManager
    }

    fileprivate func prepareRuntimeMounts(
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

    fileprivate func waitForNFSGuestIP(macAddress: VZMACAddress) async throws -> GuestIP {
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

    fileprivate func makeRuntimeMountScript(
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

    fileprivate func runtimeMountSnippet(
        mount: MountConfig,
        dvmMountsDir: String,
        manifestPath: String,
        nfsHostIP: GuestIP?
    ) throws -> (functionBody: String, callLine: String) {
        let mountPathRaw = runtimeMountPath(for: mount, dvmMountsDir: dvmMountsDir)
        let setupLines = runtimeMountSetupLines(mount: mount, mountPathRaw: mountPathRaw)
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

    fileprivate func runtimeMountPath(for mount: MountConfig, dvmMountsDir: String) -> String {
        mount.guestPath.rawValue.hasPrefix(guestHome + "/")
            ? "\(dvmMountsDir)/\(mount.tag.rawValue)"
            : mount.guestPath.rawValue
    }

    fileprivate func runtimeMountSetupLines(mount: MountConfig, mountPathRaw: String) -> String {
        let guestPath = mount.guestPath.rawValue
        guard guestPath.hasPrefix(guestHome + "/") else {
            let quotedPath = shellQuote(guestPath)
            return "[ -L \(quotedPath) ] && rm -f \(quotedPath); mkdir -p \(quotedPath)"
        }
        let mountPath = shellQuote(mountPathRaw)
        let quotedPath = shellQuote(guestPath)
        let parentDir = shellQuote(URL(fileURLWithPath: guestPath).deletingLastPathComponent().path)
        return [
            "mkdir -p \(mountPath)",
            "mkdir -p \(parentDir)",
            """
      if [ -L \(quotedPath) ]; then ln -sfn \(mountPath) \(quotedPath); \
      elif [ -d \(quotedPath) ]; then \
        if [ -z \"$(ls -A \(quotedPath) 2>/dev/null)\" ]; then \
          rmdir \(quotedPath) && ln -sfn \(mountPath) \(quotedPath); \
        else echo \"WARNING: \(quotedPath) is a non-empty directory, expected symlink.\" >&2; \
          echo \"Remove it manually: rm -rf \(quotedPath)\" >&2; fi; \
      else ln -sfn \(mountPath) \(quotedPath); fi
      """
        ].joined(separator: "\n")
    }

    fileprivate func makeRuntimeMountFunction(
        mount: MountConfig,
        mountPathRaw: String,
        manifestPath: String,
        nfsHostIP: GuestIP?,
        functionName: String
    ) throws -> String {
        let mountPath = shellQuote(mountPathRaw)
        let privateMountPathRaw =
            mountPathRaw.hasPrefix("/private/") ? mountPathRaw : "/private" + mountPathRaw
        let quotedTag = shellQuote(mount.tag.rawValue)
        let transport = shellQuote(mount.transport.rawValue)
        let writeManifest =
            "printf '%s %s %s\\n' \(transport) \(quotedTag) \(mountPath) >> \(manifestPath)"
        let tagLogPath = shellQuote("/tmp/dvm-mount-logs/\(mount.tag.rawValue).log")
        let displayPrefixText =
            "[\(mount.tag.rawValue)] \(mount.hostPath.rawValue) -> \(mount.guestPath.rawValue)"
            + " (\(mount.transport.rawValue))"
        let displayPrefix = shellQuote(displayPrefixText)
        let mountDetails = try runtimeMountDetails(mount: mount, mountPath: mountPath, nfsHostIP: nfsHostIP)
        let prelude = runtimeMountFunctionPrelude(
            functionName: functionName,
            tagLogPath: tagLogPath,
            mountPathRaw: mountPathRaw,
            privateMountPathRaw: privateMountPathRaw,
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

    fileprivate func runtimeMountFunctionPrelude(
        functionName: String,
        tagLogPath: String,
        mountPathRaw: String,
        privateMountPathRaw: String,
        mount: MountConfig,
        command: String
    ) -> String {
        """
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

    fileprivate func runtimeMountAlreadyMountedBlock(
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

    fileprivate func runtimeMountRetryLoop(
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

    fileprivate func runtimeMountDetails(
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

    fileprivate func logRuntimeMountDiagnostics(
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
           !manifest.isEmpty {
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
