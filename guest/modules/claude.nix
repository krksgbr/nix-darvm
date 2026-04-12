# Claude guest runtime adapter.
#
# Shared agent config (enable/pkg/configDir/files) comes from ai-agents via
# config.hjem.users.<user>.ai.renderedAgents.claude.
# This module owns only guest runtime behavior: wrapper generation, guest-only
# flags, credential env sourcing, and npm/pnpm fallback.
#
# Requires VM restart when first enabled — VirtioFS home-dir mounts
# (e.g. ~/.claude) are configured at boot time by the host. dvm switch alone
# is sufficient for subsequent binary/flag changes.
{
  lib,
  config,
  pkgs,
  username ? "admin",
  ...
}:

let
  cfg = config.dvm.agents.claude;
  agent = config.hjem.users.${username}.ai.renderedAgents.claude;
  direnvEnabled = config.dvm.integrations.direnv.enable;
  resumeArgs = [ "--continue" ];
  flags = (lib.optional cfg.fullAccess "--dangerously-skip-permissions") ++ cfg.extraArgs;
  renderedFlagArgs = lib.concatStringsSep "\n" (map (arg: ''args+=(${lib.escapeShellArg arg})'') flags);
  renderedResumeArgs = lib.concatStringsSep "\n" (map (arg: ''set -- "$@" ${lib.escapeShellArg arg}'') resumeArgs);
  globalCredentialsEnv = "/var/run/dvm-state/global-credentials.env";

  # When package is set declaratively via ai-agents: bake the nix store path
  # into the wrapper. When null: resolve from npm/pnpm global paths at runtime.
  claudeWrapper =
    if agent.pkg != null then
      pkgs.writeShellScriptBin "claude" ''
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
          exec direnv exec . ${agent.pkg}/bin/claude "''${args[@]}"
        else
          exec ${agent.pkg}/bin/claude "''${args[@]}"
        fi
      ''
    else
      pkgs.writeShellScriptBin "claude" ''
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
          [ -x "$_dir/claude" ] || continue
          _bin="$_dir/claude"
          break
        done
        if [ -z "$_bin" ]; then
          echo "dvm: claude not found in npm/pnpm global paths" >&2
          echo "     npm:  npm install -g @anthropic-ai/claude-code" >&2
          echo "     pnpm: pnpm add -g @anthropic-ai/claude-code" >&2
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
  options.dvm.agents.claude = {
    autoResume = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Resume the last Claude session on a bare `claude` invocation inside the guest.";
    };
    fullAccess = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Skip permission prompts (--dangerously-skip-permissions). Safe inside the VM sandbox.";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional CLI arguments passed to claude";
    };
  };

  config = lib.mkIf agent.enable {
    environment.systemPackages = [
      claudeWrapper
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
    ];
    assertions = [
      {
        assertion = agent.configDir == ".claude";
        message = ''
          dvm Claude wrapper currently assumes ai.agents.claude.configDir = ".claude".
          If you need another path, teach the guest runtime how to point Claude at it.
        '';
      }
    ];
  };
}
