{ lib, config, pkgs, ... }:

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

  config = lib.mkIf config.dvm.agents.claude.enable {
    environment.systemPackages = [
      config.dvm.agents.claude.package
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
    ];
  };
}
