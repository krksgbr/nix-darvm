{ pkgs, username ? "admin", ... }:

let
  daemonSock = "/tmp/nix-daemon.sock";
  # Fixed path — baked into base image via Packer, not from nix store.
  # The RPC component must run before /nix/store is mounted (it handles the mount).
  agentBin = "/usr/local/bin/darvm-agent";
in
{
  nix.enable = false;
  networking.hostName = "dvm";
  system.primaryUser = username;

  # SSH: keep enabled as fallback, but no longer on the critical boot path
  environment.etc."ssh/sshd_config.d/200-dvm.conf".text = ''
    PasswordAuthentication yes
    UsePAM yes
  '';

  # NOTE: darvm-agent launchd plists (com.darvm.agent-rpc, com.darvm.agent-bridge)
  # are installed by Packer into the base image, NOT managed by nix-darwin.
  # This is intentional — nix-darwin activation would restart the agent,
  # killing the gRPC connection that's driving the activation itself.

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

  environment.systemPackages = with pkgs; [
    nix
  ];

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
}
