{ pkgs, lib, config, username ? "admin", darvm-agent, dvm-host-cmd, ... }:

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
    nix.enable = false;
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
    '';

    # Materialize capabilities manifest for the host bridge
    environment.etc."dvm/capabilities.json".text =
      builtins.toJSON config.dvm.capabilities;

    environment.systemPackages = with pkgs; [
      nix
      dvm-host-cmd
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
      AGENT_VM = "1";
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
