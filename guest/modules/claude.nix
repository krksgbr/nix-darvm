# Requires VM restart when first enabled — VirtioFS home-dir mounts
# (e.g. ~/.claude) are configured at boot time by the host. dvm switch alone
# is sufficient for subsequent binary/flag changes.
{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.dvm.agents.claude;
  direnvEnabled = config.dvm.integrations.direnv.enable;
  direnvPrefix = lib.optionalString direnvEnabled "direnv exec . ";
  flags = (lib.optional cfg.fullAccess "--dangerously-skip-permissions") ++ cfg.extraArgs;
  flagsStr = lib.concatStringsSep " " flags;
  globalCredentialsEnv = "/var/run/dvm-state/global-credentials.env";

  # When package is set: bake the nix store path into the wrapper.
  # When null: resolve from npm/pnpm global paths at runtime.
  claudeWrapper =
    if cfg.package != null then
      pkgs.writeShellScriptBin "claude" ''
        if [ -f ${lib.escapeShellArg globalCredentialsEnv} ]; then
          . ${lib.escapeShellArg globalCredentialsEnv}
        fi
        exec ${direnvPrefix}${cfg.package}/bin/claude ${flagsStr} "$@"
      ''
    else
      pkgs.writeShellScriptBin "claude" ''
        if [ -f ${lib.escapeShellArg globalCredentialsEnv} ]; then
          . ${lib.escapeShellArg globalCredentialsEnv}
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
        exec ${direnvPrefix}"$_bin" ${flagsStr} "$@"
      '';
in
{
  options.dvm.agents.claude = {
    enable = lib.mkEnableOption "Claude Code agent";
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Claude Code nix package. When null, the wrapper resolves the binary at
        runtime from npm/pnpm global paths — pair with dvm.nodejs.enable
        and run: npm install -g @anthropic-ai/claude-code
      '';
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
      default = [ ];
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
