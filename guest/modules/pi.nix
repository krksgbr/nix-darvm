# Pi guest runtime adapter.
#
# Shared agent config (enable/pkg/configDir/files) comes from ai-agents via
# config.hjem.users.<user>.ai.renderedAgents.pi.
# This module owns only guest runtime behavior: wrapper generation, guest-only
# args, credential env sourcing, and npm/pnpm fallback.
#
# Requires VM restart when first enabled — VirtioFS home-dir mounts
# (e.g. ~/.pi/agent) are configured at boot time by the host. dvm switch alone
# is sufficient for subsequent binary/flag changes.
#
# Caveats:
#
# 1. No separate unsafe-mode flag — unlike Claude/Codex, pi does not need an
#    extra CLI flag here. The guest wrapper just runs pi directly (plus any
#    configured extraArgs / auto-resume behavior).
#
# 2. configDir override — the default (.pi/agent) matches pi's default lookup
#    path so no env var is needed. If you change configDir, pi won't find the
#    new location unless you also set PI_CODING_AGENT_DIR to match (e.g. via
#    environment.variables in your dvmConfiguration).
{
  lib,
  config,
  pkgs,
  username ? "admin",
  ...
}:

let
  cfg = config.dvm.agents.pi;
  agent = config.hjem.users.${username}.ai.renderedAgents.pi;
  direnvEnabled = config.dvm.integrations.direnv.enable;
  resumeArgs = [ "--continue" ];
  renderedFlagArgs = lib.concatStringsSep "\n" (map (arg: ''args+=(${lib.escapeShellArg arg})'') cfg.extraArgs);
  renderedResumeArgs = lib.concatStringsSep "\n" (map (arg: ''set -- "$@" ${lib.escapeShellArg arg}'') resumeArgs);
  globalCredentialsEnv = "/var/run/dvm-state/global-credentials.env";

  # When package is set declaratively via ai-agents: bake the nix store path
  # into the wrapper. When null: resolve from npm/pnpm global paths at runtime.
  piWrapper =
    if agent.pkg != null then
      pkgs.writeShellScriptBin "pi" ''
        if [ -f ${lib.escapeShellArg globalCredentialsEnv} ]; then
          . ${lib.escapeShellArg globalCredentialsEnv}
        fi
        if [ "$#" -eq 0 ] && ${if cfg.autoResume then "true" else "false"}; then
          set --
          ${renderedResumeArgs}
        fi
        args=()
        ${renderedFlagArgs}
        args+=("$@")
        if ${if direnvEnabled then "true" else "false"}; then
          exec direnv exec . ${agent.pkg}/bin/pi "''${args[@]}"
        else
          exec ${agent.pkg}/bin/pi "''${args[@]}"
        fi
      ''
    else
      pkgs.writeShellScriptBin "pi" ''
        if [ -f ${lib.escapeShellArg globalCredentialsEnv} ]; then
          . ${lib.escapeShellArg globalCredentialsEnv}
        fi
        if [ "$#" -eq 0 ] && ${if cfg.autoResume then "true" else "false"}; then
          set --
          ${renderedResumeArgs}
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
        args=()
        ${renderedFlagArgs}
        args+=("$@")
        if ${if direnvEnabled then "true" else "false"}; then
          exec direnv exec . "$_bin" "''${args[@]}"
        else
          exec "$_bin" "''${args[@]}"
        fi
      '';
in
{
  options.dvm.agents.pi = {
    autoResume = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Resume the last Pi session on a bare `pi` invocation inside the guest.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional CLI arguments passed to pi";
    };
  };

  config = lib.mkIf agent.enable {
    environment.systemPackages = [
      piWrapper
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
    ];
    assertions = [
      {
        assertion = agent.configDir == ".pi/agent";
        message = ''
          dvm Pi wrapper currently assumes ai.agents.pi.configDir = ".pi/agent".
          If you need another path, also teach the guest runtime to set PI_CODING_AGENT_DIR.
        '';
      }
    ];
  };
}
