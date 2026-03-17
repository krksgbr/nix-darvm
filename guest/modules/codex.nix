{ lib, config, pkgs, ... }:

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
      default = [];
      description = "Additional CLI arguments passed to codex";
    };
  };

  config = lib.mkIf config.dvm.agents.codex.enable {
    environment.systemPackages = [
      config.dvm.agents.codex.package
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
    ];
  };
}
