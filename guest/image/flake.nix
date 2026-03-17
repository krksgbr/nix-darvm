{
  description = "nix-darwin config for dvm guest (baked into base image)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-darwin }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};

      dvm-vsock-bridge = pkgs.buildGoModule {
        pname = "dvm-vsock-bridge";
        version = "0.1.0";
        src = ./vsock-bridge;
        vendorHash = "sha256-9dbQ9/11ssqzsMuGbha46H4gvsXlA77V3Fd9Fm4bqrY=";
      };
    in
    {
      darwinConfigurations.dvm = nix-darwin.lib.darwinSystem {
        inherit system;
        specialArgs = { inherit dvm-vsock-bridge; };
        modules = [ ./guest.nix ];
      };
    };
}
