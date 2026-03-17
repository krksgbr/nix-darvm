{
  description = "DVM — macOS VM sandbox for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.url = "github:numtide/llm-agents.nix";
    hjem.url = "github:feel-co/hjem";
    hjem.inputs.nixpkgs.follows = "nixpkgs";
    hjem.inputs.nix-darwin.follows = "nix-darwin";
  };

  outputs = { self, nixpkgs, nix-darwin, llm-agents, hjem }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;
      llmPkgs = llm-agents.packages.${system};

      mkDarvm = import ./nix/mk-darvm.nix { inherit nixpkgs nix-darwin hjem system; };

      # Wraps a locally-built dvm-core binary (requires --impure).
      # Build first with: just build [release]
      # TODO: nixpkgs ships Swift 5.10.1 but we need 6.0+, so we can't build
      # Swift inside a pure Nix derivation yet. Revisit when nixpkgs catches up.
      dvm-core = let
        config = if builtins.getEnv "CONFIG" != "" then builtins.getEnv "CONFIG" else "debug";
        bin = builtins.path {
          path = /. + (builtins.getEnv "PWD") + "/build/swift/${config}/dvm-core";
          name = "dvm-core-bin";
        };
      in pkgs.runCommand "dvm-core" {} ''
        mkdir -p $out/bin
        cp ${bin} $out/bin/dvm-core
        chmod +x $out/bin/dvm-core
      '';

      dvm = mkDarvm {
        inherit dvm-core;
        modules = [{
          dvm.agents.claude.enable = true;
          dvm.agents.claude.package = llmPkgs.claude-code;
          dvm.agents.codex.enable = true;
          dvm.agents.codex.package = llmPkgs.codex;
          dvm.integrations.direnv.enable = true;
        }];
      };
    in
    {
      lib = { inherit mkDarvm; };

      modules = {
        guest-plumbing = ./guest/modules/guest-plumbing.nix;
        prelude = ./guest/modules/prelude.nix;
        agents = ./guest/modules/agents.nix;
        claude = ./guest/modules/claude.nix;
        codex = ./guest/modules/codex.nix;
        direnv = ./guest/modules/direnv.nix;
      };

      packages.${system} = {
        default = dvm;
        inherit dvm dvm-core;
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          go-task
        ];
        shellHook = ''
          # Make DVM_CORE overridable from local build
          if [ -x "$PWD/build/swift/debug/dvm-core" ]; then
            export DVM_CORE="$PWD/build/swift/debug/dvm-core"
          elif [ -x "$PWD/build/swift/release/dvm-core" ]; then
            export DVM_CORE="$PWD/build/swift/release/dvm-core"
          fi
        '';
      };
    };
}
