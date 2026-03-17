# Direnv integration for DVM.
# When enabled, installs direnv + nix-direnv in the guest and wraps
# exec/agent commands with `direnv exec .` so project devShells activate
# automatically.
{ config, lib, ... }:
{
  options.dvm.integrations.direnv.enable = lib.mkEnableOption "direnv integration";

  config = lib.mkIf config.dvm.integrations.direnv.enable {
    programs.direnv.enable = true;
    programs.direnv.nix-direnv.enable = true;

    # Trust all .envrc files — safe in a sandbox VM.
    # nix-darwin sets DIRENV_CONFIG=/etc/direnv, so put the whitelist there.
    environment.etc."direnv/direnv.toml".text = ''
      [whitelist]
      prefix = [ "/" ]
    '';
  };
}
