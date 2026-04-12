# DVM adapter for the shared ai-agents flake.
#
# Ownership split:
# - ai-agents owns the agent config model and renders files/packages/configDir.
# - DVM owns only guest runtime mechanics (wrappers, flags, mount transport).
#
# This module is intentionally thin: import the shared Hjem adapter, then derive
# the guest home mounts from the rendered agent config tree.
{
  lib,
  config,
  username ? "admin",
  aiAgents,
  ...
}:

let
  inherit (config.hjem.users.${username}.ai) renderedAgents;
  enabledConfigDirs = lib.mapAttrsToList (_: agent: agent.configDir) (
    lib.filterAttrs (_: agent: agent.enable) renderedAgents
  );
in
{
  config = {
    hjem.extraModules = [ aiAgents.hjemModules.default ];
    dvm.mounts.home = enabledConfigDirs;
  };
}
