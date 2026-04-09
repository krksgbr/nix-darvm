# Requires VM restart when first enabled — VirtioFS home-dir mounts
# (e.g. ~/.config/opencode) are configured at boot time by the host.
# dvm switch alone is sufficient for subsequent binary/flag changes.
#
# Caveats:
#
# 1. Auth/state split — opencode uses two directories:
#      ~/.config/opencode          — settings, theme (mounted from host via configDir)
#      ~/.local/share/opencode     — auth tokens, logs, MCP auth (NOT mounted)
#    ~/.local is reserved for the guest's local APFS disk (fsync semantics).
#    Authenticate inside the VM after first start; auth persists across dvm switch.
#
# 2. No auto-approve flag — opencode has no equivalent of claude's
#    --dangerously-skip-permissions or codex's --full-auto. For non-interactive
#    agent use, invoke as: opencode run "your prompt"
#
# 3. configDir override — the default (.config/opencode) matches opencode's
#    XDG default so no env var is needed. If you change configDir, opencode
#    won't find the new location unless you also pass OPENCODE_CONFIG_DIR via
#    the environment or point to it explicitly.
{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.dvm.agents.opencode;
  direnvEnabled = config.dvm.integrations.direnv.enable;
  direnvPrefix = lib.optionalString direnvEnabled "direnv exec . ";
  flagsStr = lib.concatStringsSep " " cfg.extraArgs;

  # When package is set: bake the nix store path into the wrapper.
  # When null: resolve from npm/pnpm global paths at runtime.
  opencodeWrapper =
    if cfg.package != null then
      pkgs.writeShellScriptBin "opencode" ''
        exec ${direnvPrefix}${cfg.package}/bin/opencode ${flagsStr} "$@"
      ''
    else
      pkgs.writeShellScriptBin "opencode" ''
        _bin=""
        for _dir in \
          "''${NPM_CONFIG_PREFIX:-$HOME/.npm-global}/bin" \
          "''${PNPM_HOME:+$PNPM_HOME}"; do
          [ -n "$_dir" ] || continue
          [ -x "$_dir/opencode" ] || continue
          _bin="$_dir/opencode"
          break
        done
        if [ -z "$_bin" ]; then
          echo "dvm: opencode not found in npm/pnpm global paths" >&2
          echo "     npm:  npm install -g opencode" >&2
          echo "     pnpm: pnpm add -g opencode" >&2
          exit 1
        fi
        exec ${direnvPrefix}"$_bin" ${flagsStr} "$@"
      '';
in
{
  options.dvm.agents.opencode = {
    enable = lib.mkEnableOption "OpenCode agent";
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        OpenCode nix package. When null, the wrapper resolves the binary at
        runtime from npm/pnpm global paths — pair with dvm.nodejs.enable
        and run: npm install -g opencode
      '';
    };
    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".config/opencode";
      description = ''
        Config directory relative to $HOME (mounted from host).
        Covers settings and theme. Auth tokens live in ~/.local/share/opencode
        on the guest's local APFS disk and are not shared from the host.
      '';
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional CLI arguments passed to opencode";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      opencodeWrapper
      pkgs.git
      pkgs.ripgrep
      pkgs.fd
    ];
    dvm.mounts.home = [ cfg.configDir ];
  };
}
