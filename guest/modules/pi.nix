# Requires VM restart when first enabled — VirtioFS home-dir mounts
# (e.g. ~/.pi/agent) are configured at boot time by the host. dvm switch alone
# is sufficient for subsequent binary/flag changes.
#
# Caveats:
#
# 1. No auto-approve flag — pi has no equivalent of claude's
#    --dangerously-skip-permissions or codex's --full-auto. There is no
#    non-interactive / auto-approve mode at the CLI level.
#
# 2. configDir override — the default (.pi/agent) matches pi's default lookup
#    path so no env var is needed. If you change configDir, pi won't find the
#    new location unless you also set PI_CODING_AGENT_DIR to match (e.g. via
#    environment.variables in your dvmConfiguration).
{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.dvm.agents.pi;
  direnvEnabled = config.dvm.integrations.direnv.enable;
  direnvPrefix = lib.optionalString direnvEnabled "direnv exec . ";
  flagsStr = lib.concatStringsSep " " cfg.extraArgs;
  globalCredentialsEnv = "/var/run/dvm-state/global-credentials.env";

  # When package is set: bake the nix store path into the wrapper.
  # When null: resolve from npm/pnpm global paths at runtime.
  piWrapper =
    if cfg.package != null then
      pkgs.writeShellScriptBin "pi" ''
        if [ -f ${lib.escapeShellArg globalCredentialsEnv} ]; then
          . ${lib.escapeShellArg globalCredentialsEnv}
        fi
        exec ${direnvPrefix}${cfg.package}/bin/pi ${flagsStr} "$@"
      ''
    else
      pkgs.writeShellScriptBin "pi" ''
        if [ -f ${lib.escapeShellArg globalCredentialsEnv} ]; then
          . ${lib.escapeShellArg globalCredentialsEnv}
        fi
        _bin=""
        for _dir in \
          "''${NPM_CONFIG_PREFIX:-$HOME/.npm-global}/bin" \
          "''${PNPM_HOME:+$PNPM_HOME}"; do
          [ -n "$_dir" ] || continue
          [ -x "$_dir/pi" ] || continue
          _bin="$_dir/pi"
          break
        done
        if [ -z "$_bin" ]; then
          echo "dvm: pi not found in npm/pnpm global paths" >&2
          echo "     npm:  npm install -g @mariozechner/pi-coding-agent" >&2
          echo "     pnpm: pnpm add -g @mariozechner/pi-coding-agent" >&2
          exit 1
        fi
        exec ${direnvPrefix}"$_bin" ${flagsStr} "$@"
      '';
in
{
  options.dvm.agents.pi = {
    enable = lib.mkEnableOption "Pi coding agent";
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Pi coding agent nix package. When null, the wrapper resolves the binary at
        runtime from npm/pnpm global paths — pair with dvm.nodejs.enable
        and run: npm install -g @mariozechner/pi-coding-agent
      '';
    };
    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".pi/agent";
      description = ''
        Agent directory relative to $HOME (mounted from host).
        Stores config, sessions, skills, prompts, and themes.
        Corresponds to PI_CODING_AGENT_DIR.
      '';
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional CLI arguments passed to pi";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      piWrapper
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
    ];
    dvm.mounts.home = [ cfg.configDir ];
  };
}
