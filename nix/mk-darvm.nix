# mkDarvm internal constructor — evaluate a nix-darwin system configuration
# for a dvm guest VM.
#
# This is the low-level helper used by the public `lib.mkDarvm` wrapper in the
# flake output. It still requires explicit guest plumbing binaries so the flake
# can inject its packaged defaults while keeping the internal wiring testable.
#
# Returns a darwinSystem result (not a wrapper package). The caller puts this
# into dvmConfigurations.<name> in their flake. The wrapper is built separately
# by mk-dvm-wrapper.nix.

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
