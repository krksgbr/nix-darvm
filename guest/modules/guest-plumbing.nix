{ pkgs, lib, config, username ? "admin", darvm-agent, dvm-host-cmd, determinate-nix, ... }:

let
  daemonSock = "/tmp/nix-daemon.sock";
in
{
  # Agents declare home-relative directories they need mounted from the host.
  # Materialized as JSON in the closure so the wrapper can read it at runtime.
  options.dvm.mounts.home = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Home-relative directories to VirtioFS-mount from the host";
  };

  # Absolute paths to mount read-only from the host (same path in guest).
  # Used for system-level toolchains like Xcode that should be shared
  # immutably — the guest gets the host's installation without modification.
  options.dvm.mounts.system = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "Absolute paths to VirtioFS-mount read-only from the host (same path in guest)";
  };

  # Host actions: name → handler script in the nix store.
  # Each capability gets a symlink in the guest (bin/<name> → dvm-host-cmd)
  # and an entry in the capabilities manifest read by the host bridge.
  # Handlers receive payload on stdin and run with a scrubbed environment.
  options.dvm.capabilities = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = {};
    description = "Host actions: name → handler script. Handlers receive payload on stdin.";
  };

  config = {
    determinateNix.enable = true;
    determinateNix.customSettings = {
      accept-flake-config = true;
    };
    networking.hostName = "dvm";
    system.primaryUser = username;

    # SSH: keep enabled as fallback, but not on the critical boot path
    environment.etc."ssh/sshd_config.d/200-dvm.conf".text = ''
      PasswordAuthentication yes
      UsePAM yes
    '';

    # Materialize home mounts list for the wrapper to read from the closure
    environment.etc."dvm/home-mounts.json".text =
      builtins.toJSON config.dvm.mounts.home;

    # Agent LaunchDaemons — managed by nix-darwin, NOT baked into the image.
    # This is safe because activation is driven by the WatchPaths activator
    # daemon (independent of the agent). If the agent restarts during activation,
    # the activator continues running unaffected.
    # Agent LaunchDaemons use /bin/sh wrappers because the agent binary lives in
    # /nix/store (VirtioFS mount). On boot, launchd may start these before the
    # mount script completes. If launchd can't find the binary, it reports exit
    # code 78 (EX_CONFIG) and PERMANENTLY disables the job — KeepAlive won't help.
    # The shell wrapper busy-waits for the binary, avoiding the fatal exit code.
    launchd.daemons.darvm-agent-rpc = {
      serviceConfig = {
        Label = "com.darvm.agent-rpc";
        ProgramArguments = [
          "/bin/sh" "-c"
          "while [ ! -x '${darvm-agent}/bin/darvm-agent' ]; do sleep 1; done; exec '${darvm-agent}/bin/darvm-agent' '--run-rpc'"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/var/log/darvm-agent.log";
        StandardErrorPath = "/var/log/darvm-agent.log";
      };
    };

    launchd.daemons.darvm-agent-bridge = {
      serviceConfig = {
        Label = "com.darvm.agent-bridge";
        ProgramArguments = [
          "/bin/sh" "-c"
          "while [ ! -x '${darvm-agent}/bin/darvm-agent' ]; do sleep 1; done; exec '${darvm-agent}/bin/darvm-agent' '--run-bridge'"
        ];
        RunAtLoad = true;
        KeepAlive = true;
      };
    };

    # Point the default nix daemon socket to our bridge socket.
    # Determinate Nix creates /nix/var/nix/daemon-socket/socket -> /var/run/nix-daemon.socket.
    # We replace /var/run/nix-daemon.socket with a symlink to our bridge socket so
    # nix clients connect through the vsock bridge without any env var overrides.
    # Rename files from the base image's Determinate Nix installer so
    # nix-darwin's determinateNix module can manage them.
    system.activationScripts.preActivation.text = ''
      if [ -e /etc/nix/nix.custom.conf ] && [ ! -e /etc/nix/nix.custom.conf.before-nix-darwin ]; then
        mv /etc/nix/nix.custom.conf /etc/nix/nix.custom.conf.before-nix-darwin
      fi
    '';

    system.activationScripts.postActivation.text = ''
      rm -f /var/run/nix-daemon.socket
      ln -s ${daemonSock} /var/run/nix-daemon.socket

      # Ensure /run/current-system exists. The nix-darwin activate script uses
      # readlink -f which may fail on stock macOS (no GNU coreutils in PATH yet).
      ln -sfn /nix/var/nix/profiles/system /run/current-system

      # Disable link-nix-apps: it calls `launchctl kickstart gui/501/...` which
      # hangs indefinitely in a headless VM with no GUI login session.
      launchctl bootout gui/501/org.nix.link-nix-apps 2>/dev/null || true
      rm -f /Library/LaunchAgents/org.nix.link-nix-apps.plist

      # hjem manages user-level config (starship, dotfiles) via a LaunchAgent
      # that only triggers at GUI login. In a headless VM there is no GUI
      # session, so run it explicitly. hjem-activate is idempotent (manifest
      # diffing), safe to run on every activation.
      sudo -u ${username} HOME=/Users/${username} \
        ${config.launchd.user.agents.hjem-activate.serviceConfig.Program} || {
        echo "WARNING: hjem activation failed for ${username}" >&2
      }
    '';

    # Materialize system mounts list for the wrapper to read from the closure
    environment.etc."dvm/system-mounts.json".text =
      builtins.toJSON config.dvm.mounts.system;

    # Materialize capabilities manifest for the host bridge
    environment.etc."dvm/capabilities.json".text =
      builtins.toJSON config.dvm.capabilities;

    environment.systemPackages = [
      determinate-nix
      dvm-host-cmd
      (pkgs.writeShellScriptBin "dvctl" ''
        SERVICES="com.darvm.agent-rpc com.darvm.agent-bridge"

        usage() {
          echo "Usage: dvctl <command> [args]"
          echo ""
          echo "Commands:"
          echo "  mounts                 Show runtime mount manifest and live fs state"
          echo "  status                 Show status of all DVM services"
          echo "  restart agent-bridge   Restart the nix daemon bridge"
          echo "  restart agent-rpc      Restart the gRPC agent"
          echo "  remount                Remount project VirtioFS shares (fixes stale file cache)"
        }

        cmd_status() {
          for svc in $SERVICES; do
            if sudo launchctl print "system/$svc" >/dev/null 2>&1; then
              pid=$(sudo launchctl print "system/$svc" 2>/dev/null | grep '^\s*pid' | awk '{print $3}')
              echo "  $svc: running (pid ''${pid:-?})"
            else
              echo "  $svc: stopped"
            fi
          done
        }

        cmd_mounts() {
          local manifest=/var/dvm-mounts/.manifest
          if [ ! -f "$manifest" ]; then
            echo "No mount manifest at $manifest — is the VM fully started?" >&2
            return 1
          fi

          while read -r kind tag path; do
            [ -n "$kind" ] || continue
            private_path="$path"
            case "$private_path" in
              /private/*) ;;
              *) private_path="/private$path" ;;
            esac
            line=$(
              /sbin/mount | awk -v path="$path" -v private="$private_path" '
                index($0, " on " path " ") || index($0, " on " private " ") { print; exit }
              '
            )
            if [ -n "$line" ]; then
              printf "  %-8s %-12s %s\n" "$kind" "$tag" "$path"
              printf "    mount: %s\n" "$line"
            else
              printf "  %-8s %-12s %s\n" "$kind" "$tag" "$path"
              printf "    mount: MISSING\n"
            fi
          done < "$manifest"
        }

        # Remount all mirror-* VirtioFS shares.
        # macOS VirtioFS doesn't invalidate guest dentry cache when the host
        # atomically replaces a file (rename). After a host editor saves a file,
        # the guest sees the old deleted inode (link count 0) and cat/open fail
        # with ENOENT. Remounting discards the stale cache.
        # Note: cd out of any project directory first, or umount will fail.
        #
        # We read /var/dvm-mounts/.manifest (written by dvm-core at startup)
        # to get the transport, tag, and path for each runtime mount.
        # NFS mirrors intentionally skip this workaround — the coherency bug is
        # specific to VirtioFS.
        cmd_remount() {
          local manifest=/var/dvm-mounts/.manifest
          if [ ! -f "$manifest" ]; then
            echo "No mount manifest at $manifest — is the VM fully started?" >&2
            return 1
          fi
          grep '^[^ ]\+ mirror-' "$manifest" | while read -r kind tag path; do
            if [ "$kind" = "nfs" ]; then
              printf "  %s -> %s ... skip (NFS mirror mounts do not need VirtioFS remount)\n" "$tag" "$path"
              continue
            fi
            printf "  %s -> %s ... " "$tag" "$path"
            if ! sudo /sbin/umount "$path" 2>/dev/null; then
              printf "FAILED (device busy — cd out of %s first)\n" "$path" >&2
              continue
            fi
            if sudo /sbin/mount_virtiofs "$tag" "$path" 2>/dev/null; then
              printf "ok\n"
            else
              printf "remount FAILED\n" >&2
            fi
          done
        }

        case "''${1:-}" in
          mounts) cmd_mounts ;;
          status) cmd_status ;;
          restart)
            case "''${2:-}" in
              agent-bridge) sudo launchctl kickstart -k system/com.darvm.agent-bridge ;;
              agent-rpc)    sudo launchctl kickstart -k system/com.darvm.agent-rpc ;;
              *) echo "Unknown service: ''${2:-}" >&2; usage >&2; exit 1 ;;
            esac
            ;;
          remount) cmd_remount ;;
          -h|--help|help) usage ;;
          *) echo "Unknown command: ''${1:-}" >&2; usage >&2; exit 1 ;;
        esac
      '')
    ] ++ lib.optional (config.dvm.capabilities != {}) (
      # Create bin/<name> → dvm-host-cmd symlinks for each capability
      pkgs.runCommand "dvm-capability-symlinks" {} (
        let names = builtins.attrNames config.dvm.capabilities; in
        ''
          mkdir -p $out/bin
          ${lib.concatMapStringsSep "\n" (name:
            "ln -s ${dvm-host-cmd}/bin/dvm-host-cmd $out/bin/${name}"
          ) names}
        ''
      )
    );

    environment.variables = {
      DVM_GUEST = "1";
      # Trust the DVM credential proxy's MITM CA.
      # Written to /etc/dvm-ca.pem at VM start by the host's netstack supervisor.
      # Bun and Node.js use BoringSSL/OpenSSL and don't read the macOS Keychain,
      # so NODE_EXTRA_CA_CERTS is required for HTTPS interception to work.
      NODE_EXTRA_CA_CERTS = "/etc/dvm-ca.pem";
    };

    environment.systemPath = [
      "/usr/sbin"
      "/sbin"
    ];

    environment.shellInit = ''
      # Determinate Nix only sources nix-daemon.sh for SSH connections.
      # Since we use gRPC (not SSH), source it unconditionally.
      if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
        . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
      fi
      export PATH="$HOME/.local/bin:$PATH"
    '';

    system.stateVersion = 6;
  };
}
