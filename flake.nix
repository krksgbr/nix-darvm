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
      llmPkgs = llm-agents.packages.${system};

      mkDarvm = import ./nix/mk-darvm.nix { inherit nixpkgs nix-darwin hjem system; };
      mkDvmWrapper = import ./nix/mk-dvm-wrapper.nix { inherit nixpkgs system; };
      mkCreateBaseVm = import ./nix/create-base-vm.nix { inherit nixpkgs system; };

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

      darvm-agent = pkgs.buildGoModule {
        pname = "darvm-agent";
        version = "0.1.0";
        src = ./guest/agent;
        vendorHash = "sha256-5K9Qu7avGGqh6vVTEEoAV483vAzopWMm7koKxdeQnk8=";
        subPackages = [ "cmd" ];
        postInstall = "mv $out/bin/cmd $out/bin/darvm-agent";
      };

      dvm-host-cmd = pkgs.buildGoModule {
        pname = "dvm-host-cmd";
        version = "0.1.0";
        src = ./guest/host-cmd;
        vendorHash = "sha256-9dbQ9/11ssqzsMuGbha46H4gvsXlA77V3Fd9Fm4bqrY=";
        postInstall = "mv $out/bin/host-cmd $out/bin/dvm-host-cmd";
      };

      dvm-netstack = pkgs.buildGoModule {
        pname = "dvm-netstack";
        version = "0.1.0";
        src = ./host/netstack;
        vendorHash = "sha256-WxFN5vTWLxABSchmWs77eTH7qm/FztygNzrGPtJmyys=";
        subPackages = [ "cmd" ];
        postInstall = "mv $out/bin/cmd $out/bin/dvm-netstack";
      };

      createBaseVm = mkCreateBaseVm {};

      wrapper = mkDvmWrapper {
        inherit dvm-core dvm-netstack;
        dvm-create-vm = createBaseVm;
        dvmFlakeRef = self.outPath;
      };
    in
    {
      lib = { inherit mkDarvm; };

      # Guest VM configurations. Users put their own in dvmConfigurations.default.
      # The wrapper builds dvmConfigurations.default from the user's flake at runtime,
      # falling back to dvmConfigurations.minimal from dvm's own flake.
      dvmConfigurations = {
        minimal = mkDarvm {
          inherit darvm-agent dvm-host-cmd;
          modules = [];
        };

        default = mkDarvm {
          inherit darvm-agent dvm-host-cmd;
          modules = [{
            dvm.agents.claude.enable = true;
            dvm.agents.claude.package = llmPkgs.claude-code;
            dvm.agents.codex.enable = true;
            dvm.agents.codex.package = llmPkgs.codex;
            dvm.integrations.direnv.enable = true;
          }];
        };
      };

      modules = {
        guest-plumbing = ./guest/modules/guest-plumbing.nix;
        prelude = ./guest/modules/prelude.nix;
        agents = ./guest/modules/agents.nix;
        claude = ./guest/modules/claude.nix;
        codex = ./guest/modules/codex.nix;
        direnv = ./guest/modules/direnv.nix;
      };

      packages.${system} = {
        default = wrapper;
        dvm = wrapper;
        inherit dvm-core darvm-agent dvm-host-cmd dvm-netstack;
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          just
          go
          jq
          python3
          protobuf
          protoc-gen-go
          protoc-gen-go-grpc
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
