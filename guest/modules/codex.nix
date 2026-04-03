{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.dvm.agents.codex;
  direnvEnabled = config.dvm.integrations.direnv.enable;
  direnvPrefix = lib.optionalString direnvEnabled "direnv exec . ";
  flags = (lib.optional cfg.fullAccess "--full-auto") ++ cfg.extraArgs;
  flagsStr = lib.concatStringsSep " " flags;

  codexWrapper = pkgs.writeShellScriptBin "codex" ''
    exec ${direnvPrefix}${cfg.package}/bin/codex ${flagsStr} "$@"
  '';
in
{
  options.dvm.agents.codex = {
    enable = lib.mkEnableOption "Codex agent";
    package = lib.mkOption {
      type = lib.types.package;
      description = "Codex package";
    };
    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".codex";
      description = "Config directory name relative to $HOME (mounted from host)";
    };
    fullAccess = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Bypass approval prompts (--full-auto). Safe inside the VM sandbox.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional CLI arguments passed to codex";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      codexWrapper
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
    ];
    dvm.mounts.home = [ cfg.configDir ];
  };
}
