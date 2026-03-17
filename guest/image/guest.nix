{ pkgs, dvm-vsock-bridge, ... }:

let
  daemonSock = "/tmp/nix-daemon.sock";
  vsockPort = "6174";
in
{
  nix.enable = false;

  # SSH: enable password auth for exec
  environment.etc."ssh/sshd_config.d/200-dvm.conf".text = ''
    PasswordAuthentication yes
    UsePAM yes
  '';

  # Nix daemon bridge: vsock to host's nix daemon.
  # Guest-side Go binary listens on a Unix socket. For each client connection,
  # it dials the host via AF_VSOCK (CID 2, port 6174). The host-side dvm runner
  # receives these and proxies to the host's nix daemon socket.
  launchd.daemons.nix-daemon-bridge = {
    serviceConfig = {
      Label = "com.darvm.nix-daemon-bridge";
      ProgramArguments = [
        "${dvm-vsock-bridge}/bin/dvm-vsock-bridge"
        "-listen" daemonSock
        "-vsock-port" vsockPort
      ];
      RunAtLoad = true;
      KeepAlive = true;
    };
  };

  # Point the default nix daemon socket to our bridge socket.
  # Determinate Nix creates /nix/var/nix/daemon-socket/socket → /var/run/nix-daemon.socket.
  # We replace /var/run/nix-daemon.socket with a symlink to our bridge socket so
  # nix clients connect through the vsock bridge without any env var overrides.
  system.activationScripts.postActivation.text = ''
    rm -f /var/run/nix-daemon.socket
    ln -s ${daemonSock} /var/run/nix-daemon.socket
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
    export PATH="$HOME/.local/bin:$PATH"
  '';

  system.stateVersion = 6;
}
