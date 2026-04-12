{
  description = "DVM nix/direnv regression fixture";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/4c1018dae018162ec878d42fec712642d214fdfa";

  outputs =
    { nixpkgs, ... }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        shellHook = ''
          echo "DVM nix-direnv fixture shell ready"
        '';
      };
    };
}
