# Node.js and npm for DVM guest VMs.
#
# Installs Node.js (including npm) from nixpkgs. The default package is
# `pkgs.nodejs`; override with `dvm.nodejs.package` to pin a specific version
# (e.g. `pkgs.nodejs_22`).
#
# npm's default global prefix points into the read-only nix store. This module
# redirects it to ~/.npm-global so `npm install -g` works out of the box.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dvm.nodejs;
  username = config.system.primaryUser;
in
{
  options.dvm.nodejs = {
    enable = lib.mkEnableOption "Node.js and npm";
    package = lib.mkPackageOption pkgs "nodejs" { };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # npm's default global prefix points into the read-only nix store, causing
    # EACCES on `npm install -g`. Redirect to a writable user directory.
    # Written to /etc/zshenv via environment.variables, so it applies to all
    # zsh invocations (interactive, non-interactive, login).
    environment.variables.NPM_CONFIG_PREFIX = "/Users/${username}/.npm-global";

    # Mount ~/.npm-global from the host so globally installed packages persist
    # across VM reboots. Without this, the guest home is wiped on every start.
    # Requires VM restart when first enabled (VirtioFS mounts are boot-time).
    dvm.mounts.home = [ ".npm-global" ];

    # Expose ~/.npm-global/bin in PATH for interactive shells.
    programs.zsh.interactiveShellInit = lib.mkAfter ''
      export PATH="$HOME/.npm-global/bin:$PATH"
    '';
  };
}
