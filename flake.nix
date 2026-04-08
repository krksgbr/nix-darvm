{
  description = "DVM — macOS VM sandbox for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.url = "github:numtide/llm-agents.nix";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
    hjem = {
      url = "github:feel-co/hjem";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nix-darwin.follows = "nix-darwin";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
      llm-agents,
      treefmt-nix,
      determinate,
      hjem,
    }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      llmPkgs = llm-agents.packages.${system};
      treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

      mkDarvm = import ./nix/mk-darvm.nix {
        inherit
          nix-darwin
          determinate
          hjem
          system
          ;
      };
      mkDvmWrapper = import ./nix/mk-dvm-wrapper.nix { inherit nixpkgs system; };
      mkCreateBaseVm = import ./nix/create-base-vm.nix { inherit nixpkgs system; };

      # Wraps a locally-built dvm-core binary (requires --impure).
      # Build first with: just build [release]
      # TODO: nixpkgs ships Swift 5.10.1 but we need 6.0+, so we can't build
      # Swift inside a pure Nix derivation yet. Revisit when nixpkgs catches up.
      # Tracking: https://github.com/NixOS/nixpkgs/issues/343210
      dvm-core =
        let
          config = if builtins.getEnv "CONFIG" != "" then builtins.getEnv "CONFIG" else "debug";
          bin = builtins.path {
            path = /. + (builtins.getEnv "PWD") + "/build/swift/${config}/dvm-core";
            name = "dvm-core-bin";
          };
        in
        pkgs.runCommand "dvm-core" { } ''
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

      createBaseVm = mkCreateBaseVm { };

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
          modules = [ ];
        };

        default = mkDarvm {
          inherit darvm-agent dvm-host-cmd;
          modules = [
            {
              dvm = {
                agents.claude.enable = true;
                agents.claude.package = llmPkgs.claude-code;
                agents.codex.enable = true;
                agents.codex.package = null;
                integrations.direnv.enable = true;
                xcode.enable = true;
                nodejs.enable = true;
              };
            }
            (
              { pkgs, ... }:
              {
                nixpkgs.config.allowUnfree = true;
                environment.systemPackages = with pkgs; [
                  google-chrome
                  jujutsu
                ];
              }
            )
          ];
        };
      };

      modules = {
        guest-plumbing = ./guest/modules/guest-plumbing.nix;
        prelude = ./guest/modules/prelude.nix;
        agents = ./guest/modules/agents.nix;
        claude = ./guest/modules/claude.nix;
        codex = ./guest/modules/codex.nix;
        direnv = ./guest/modules/direnv.nix;
        xcode = ./guest/modules/xcode.nix;
        nodejs = ./guest/modules/nodejs.nix;
      };

      packages.${system} = {
        default = wrapper;
        dvm = wrapper;
        inherit
          dvm-core
          darvm-agent
          dvm-host-cmd
          dvm-netstack
          ;
      };

      formatter.${system} = treefmtEval.config.build.wrapper;

      checks.${system} = {
        formatting = treefmtEval.config.build.check self;

        swift-lint =
          pkgs.runCommand "swift-lint"
            {
              nativeBuildInputs = [ pkgs.swiftlint ];
              src = self;
            }
            ''
              export HOME="$TMPDIR"
              export XDG_CACHE_HOME="$TMPDIR/cache"
              cd "$src"
              swiftlint lint --strict --quiet --no-cache --config .swiftlint.yml
              touch "$out"
            '';

        go-lint-agent =
          pkgs.runCommand "go-lint-agent"
            {
              nativeBuildInputs = [
                pkgs.go
                pkgs.golangci-lint
              ];
              src = self;
            }
            ''
              export HOME="$TMPDIR"
              export XDG_CACHE_HOME="$TMPDIR/cache"
              export GOLANGCI_LINT_CACHE="$TMPDIR/golangci-lint-cache"
              cd "$src/guest/agent"
              golangci-lint run ./...
              touch "$out"
            '';

        go-lint-netstack =
          pkgs.runCommand "go-lint-netstack"
            {
              nativeBuildInputs = [
                pkgs.go
                pkgs.golangci-lint
              ];
              src = self;
            }
            ''
              export HOME="$TMPDIR"
              export XDG_CACHE_HOME="$TMPDIR/cache"
              export GOLANGCI_LINT_CACHE="$TMPDIR/golangci-lint-cache"
              cd "$src/host/netstack"
              golangci-lint run ./...
              touch "$out"
            '';

        nix-lint =
          pkgs.runCommand "nix-lint"
            {
              nativeBuildInputs = [
                pkgs.deadnix
                pkgs.statix
              ];
              src = self;
            }
            ''
              cd "$src"
              deadnix flake.nix guest/modules nix
              statix check flake.nix
              statix check guest/modules
              statix check nix
              touch "$out"
            '';
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          deadnix
          golangci-lint
          just
          go
          jq
          python3
          protobuf
          protoc-gen-go
          protoc-gen-go-grpc
          statix
          swiftlint
          treefmtEval.config.build.wrapper
        ];
        shellHook = ''
          # Make DVM_CORE overridable from local build
          if [ -x "$PWD/build/swift/debug/dvm-core" ]; then
            export DVM_CORE="$PWD/build/swift/debug/dvm-core"
          elif [ -x "$PWD/build/swift/release/dvm-core" ]; then
            export DVM_CORE="$PWD/build/swift/release/dvm-core"
          fi
          # Make DVM_NETSTACK overridable from local build
          if [ -x "$PWD/build/dvm-netstack" ]; then
            export DVM_NETSTACK="$PWD/build/dvm-netstack"
          fi
        '';
      };
    };
}
