{ lib, config, pkgs, ... }:

let
  cfg = config.dvm.agents.claude;
  direnvEnabled = config.dvm.integrations.direnv.enable;
  direnvPrefix = lib.optionalString direnvEnabled "direnv exec . ";
  flags = (lib.optional cfg.fullAccess "--dangerously-skip-permissions") ++ cfg.extraArgs;
  flagsStr = lib.concatStringsSep " " flags;

  claudeWrapper = pkgs.writeShellScriptBin "claude" ''
    exec ${direnvPrefix}${cfg.package}/bin/claude ${flagsStr} "$@"
  '';
in
{
  options.dvm.agents.claude = {
    enable = lib.mkEnableOption "Claude Code agent";
    package = lib.mkOption {
      type = lib.types.package;
      description = "Claude Code package";
    };
    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".claude";
      description = "Config directory name relative to $HOME (mounted from host)";
    };
    fullAccess = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Skip permission prompts (--dangerously-skip-permissions). Safe inside the VM sandbox.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional CLI arguments passed to claude";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      claudeWrapper
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
    ];
    dvm.mounts.home = [ cfg.configDir ];
  };
}
