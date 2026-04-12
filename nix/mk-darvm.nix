# mkDarvm — evaluate a nix-darwin system configuration for a dvm guest VM.
#
# Returns a darwinSystem result (not a wrapper package). The caller puts
# this into dvmConfigurations.<name> in their flake. The wrapper is built
# separately by mk-dvm-wrapper.nix.

{
  nix-darwin,
  determinate,
  hjem,
  aiAgents,
  system ? "aarch64-darwin",
}:

{
  modules ? [ ],
  username ? "admin",
  darvm-agent,
  dvm-host-cmd,
}:

nix-darwin.lib.darwinSystem {
  inherit system;
  modules = [
    determinate.darwinModules.default
    hjem.darwinModules.default
    ../guest/modules/guest-plumbing.nix
    ../guest/modules/prelude.nix
    ../guest/modules/direnv.nix
    ../guest/modules/agents.nix
    ../guest/modules/xcode.nix
    ../guest/modules/nodejs.nix
  ]
  ++ modules;
  specialArgs = {
    inherit username darvm-agent dvm-host-cmd aiAgents;
    determinate-nix = determinate.inputs.nix.packages.${system}.default;
  };
}
