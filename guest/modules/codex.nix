# Requires VM restart when first enabled — VirtioFS home-dir mounts
# (e.g. ~/.codex) are configured at boot time by the host. dvm switch alone
# is sufficient for subsequent binary/flag changes.
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
  globalCredentialsEnv = "/var/run/dvm-state/global-credentials.env";

  # When package is set: bake the nix store path into the wrapper.
  # When null: resolve from npm/pnpm global paths at runtime.
  codexWrapper =
    if cfg.package != null then
      pkgs.writeShellScriptBin "codex" ''
        if [ -f ${lib.escapeShellArg globalCredentialsEnv} ]; then
          . ${lib.escapeShellArg globalCredentialsEnv}
        fi
        exec ${direnvPrefix}${cfg.package}/bin/codex ${flagsStr} "$@"
      ''
    else
      pkgs.writeShellScriptBin "codex" ''
        if [ -f ${lib.escapeShellArg globalCredentialsEnv} ]; then
          . ${lib.escapeShellArg globalCredentialsEnv}
        fi
        _bin=""
        for _dir in \
          "''${NPM_CONFIG_PREFIX:-$HOME/.npm-global}/bin" \
          "''${PNPM_HOME:+$PNPM_HOME}"; do
          [ -n "$_dir" ] || continue
          [ -x "$_dir/codex" ] || continue
          _bin="$_dir/codex"
          break
        done
        if [ -z "$_bin" ]; then
          echo "dvm: codex not found in npm/pnpm global paths" >&2
          echo "     npm:  npm install -g @openai/codex" >&2
          echo "     pnpm: pnpm add -g @openai/codex" >&2
          exit 1
        fi
        exec ${direnvPrefix}"$_bin" ${flagsStr} "$@"
      '';
in
{
  options.dvm.agents.codex = {
    enable = lib.mkEnableOption "Codex agent";
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Codex nix package. When null, the wrapper resolves the binary at
        runtime from npm/pnpm global paths — pair with dvm.nodejs.enable
        and run: npm install -g @openai/codex
      '';
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
