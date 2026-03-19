# mkDarvm — compose a complete dvm package from nix-darwin modules.
#
# Evaluates mkSandbox with the user's modules, extracts enabled agents,
# generates a bash wrapper with dynamic agent subcommands, and bundles
# everything into a single package.

{ nixpkgs, nix-darwin, hjem, system ? "aarch64-darwin" }:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = pkgs.lib;
  inherit (lib) escapeShellArg;

  mkSandbox = { modules ? [], specialArgs ? {}, username ? "admin", ... }@args:
    nix-darwin.lib.darwinSystem ({
      inherit system;
      modules = [
        hjem.darwinModules.default
        ../guest/modules/guest-plumbing.nix
        ../guest/modules/prelude.nix
        ../guest/modules/direnv.nix
      ] ++ modules;
      # darvm-agent and dvm-host-cmd are passed via specialArgs from the caller.
      specialArgs = { inherit username; } // specialArgs;
    } // builtins.removeAttrs args [ "modules" "specialArgs" "username" ]);

  mkCreateBaseVm = import ./create-base-vm.nix { inherit nixpkgs system; };
in

{
  baseImage ? "ghcr.io/cirruslabs/macos-tahoe-base@sha256:593df8dcf9f00929c9e8f19e47793657953ba14112830efa7aaccdd214410093",
  modules ? [],
  username ? "admin",
  dvm-core,
  darvm-agent,
  dvm-host-cmd,
}:

let
  darwinConfig = mkSandbox {
    inherit username;
    modules = [
      ../guest/modules/agents.nix
    ] ++ modules;
    specialArgs = { inherit darvm-agent dvm-host-cmd; };
  };

  # Extract enabled agents from evaluated config
  agentsCfg =
    if darwinConfig.config ? dvm && darwinConfig.config.dvm ? agents
    then darwinConfig.config.dvm.agents
    else {};

  enabledAgents = lib.filterAttrs (_: a: a.enable) agentsCfg;

  systemClosure = darwinConfig.config.system.build.toplevel;

  createBaseVm = mkCreateBaseVm {
    defaultBaseImage = baseImage;
  };

  # Content-addressed VM name — must match the one in create-base-vm.nix.
  # Only covers the Packer template; agent/host-cmd/module changes never trigger rebuild.
  imageInputsHash = builtins.substring 0 8 (builtins.hashString "sha256"
    "${../guest/image-minimal}");
  vmName = "darvm-${imageInputsHash}";

  # Per-agent full-access flags
  agentFullAccessFlags = {
    claude = "--dangerously-skip-permissions";
    codex = "--full-auto";
  };

  # Generate case clauses for agent subcommands
  agentCases = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: cfg:
    let
      binary = name;
      fullAccessFlag = agentFullAccessFlags.${name} or null;
      flags = (lib.optional (cfg.fullAccess && fullAccessFlag != null) fullAccessFlag)
              ++ cfg.extraArgs;
      flagsStr = lib.concatStringsSep " " (map (f: ''"${f}"'') flags);
    in ''
      ${name})
        exec "$DVM_CORE" exec -t -- ${direnvWrap} ${binary} ${flagsStr} "$@"
        ;;''
  ) enabledAgents);

  # Generate help text for agent subcommands
  agentHelp = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _:
    "  ${name}${lib.fixedWidthString (18 - builtins.stringLength name) " " ""}Launch ${name} at \\$PWD in the guest"
  ) enabledAgents);

  # Generate --home-dir flags for agent config dirs (mounted at guest home)
  agentHomeDirFlags = lib.concatStringsSep " " (lib.mapAttrsToList (_: cfg:
    ''--home-dir "''${HOME}/${cfg.configDir}"''
  ) enabledAgents);

  # When direnv integration is enabled, wrap exec/agent commands so
  # project devShells activate automatically via .envrc.
  direnvEnabled =
    darwinConfig.config ? dvm
    && darwinConfig.config.dvm ? integrations
    && darwinConfig.config.dvm.integrations ? direnv
    && darwinConfig.config.dvm.integrations.direnv.enable;
  direnvWrap = lib.optionalString direnvEnabled "direnv exec .";

in
pkgs.writeShellApplication {
  name = "dvm";
  runtimeInputs = [ dvm-core ];
  meta.mainProgram = "dvm";
  text = ''
    set -euo pipefail

    DVM_CORE="''${DVM_CORE:-${escapeShellArg "${dvm-core}/bin/dvm-core"}}"
    CREATE_VM=${escapeShellArg "${createBaseVm}/bin/dvm-create-vm"}
    SYSTEM_CLOSURE=${escapeShellArg "${systemClosure}"}

    usage() {
      cat <<USAGE
    dvm — sandboxed macOS VM for coding agents

    Usage: dvm <command> [args...]

    Commands:
      init              Create the base VM image (first-time setup)
      start             Start the VM (runs init if needed)
      stop              Stop the VM
      reboot            Stop and restart the VM
      status            Show VM status
      switch            Rebuild and activate nix-darwin config
      shell             Open interactive shell at \$PWD in the guest
      exec [cmd...]     Run a command in the guest
    ${agentHelp}

    USAGE
    }

    cmd_init() {
      "$CREATE_VM"
    }

    cmd_start() {
      # Ensure base VM exists (create-vm prompts interactively if needed).
      "$CREATE_VM"

      # Find the actual darvm-* VM name. There should be exactly one.
      ACTUAL_VM=$(tart list --format json | python3 -c 'import json,sys;vms=json.load(sys.stdin);ms=[v["Name"]for v in vms if v["Name"].startswith("darvm-")];print(ms[0])if ms else None' 2>/dev/null)
      ACTUAL_VM="''${ACTUAL_VM:-${escapeShellArg vmName}}"

      # Start dvm-core with system closure for implicit activation.
      # Mount agent config dirs at guest home (e.g. ~/.claude, ~/.codex).
      # shellcheck disable=SC2086
      exec "$DVM_CORE" start --vm-name "$ACTUAL_VM" --system-closure "$SYSTEM_CLOSURE" ${agentHomeDirFlags} "$@"
    }

    cmd_switch() {
      # Check VM is running
      "$DVM_CORE" status >/dev/null 2>&1 || {
        echo "Error: VM not running. Start it with: dvm start" >&2
        exit 1
      }

      # Write closure path + run ID, then touch trigger to fire the activator.
      # The activator daemon (WatchPaths) handles profile symlink, link-nix-apps,
      # and darwin-rebuild activate autonomously.
      local RUN_ID="switch-$$"
      echo "Activating system closure..."
      "$DVM_CORE" exec -- sudo sh -c "printf '%s' '$SYSTEM_CLOSURE' > /var/run/dvm-state/closure-path; printf '%s' '$RUN_ID' > /var/run/dvm-state/run-id; touch /var/run/dvm-state/trigger"

      # Wait for activation to complete (poll guest state files)
      echo "Waiting for activation..."
      for _i in $(seq 1 300); do
        STATUS=$("$DVM_CORE" exec -- cat "/var/run/dvm-state/$RUN_ID/status" 2>/dev/null || true)
        case "$STATUS" in
          done) echo "Switch complete."; return 0 ;;
          failed|invalid-closure)
            echo "Activation failed:" >&2
            "$DVM_CORE" exec -- tail -20 "/var/run/dvm-state/$RUN_ID/activation.log" >&2 || true
            return 1 ;;
        esac
        sleep 1
      done
      echo "Activation timed out after 5 minutes." >&2
      return 1
    }

    if [ $# -eq 0 ]; then
      usage
      exit 0
    fi

    command="$1"
    shift

    case "$command" in
      init)
        cmd_init
        ;;
      start)
        cmd_start "$@"
        ;;
      stop)
        exec "$DVM_CORE" stop "$@"
        ;;
      reboot)
        "$DVM_CORE" stop
        # Wait for the running dvm-core start process to exit
        while "$DVM_CORE" status >/dev/null 2>&1; do sleep 1; done
        cmd_start "$@"
        ;;
      status)
        exec "$DVM_CORE" status "$@"
        ;;
      switch)
        cmd_switch "$@"
        ;;
      shell)
        exec "$DVM_CORE" ssh "$@"
        ;;
      exec)
        ${if direnvEnabled then ''
        # Split flags (anything starting with -) from the command.
        flags=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --) shift; break ;;
            -*) flags+=("$1"); shift ;;
            *) break ;;
          esac
        done
        if [ $# -gt 0 ]; then
          exec "$DVM_CORE" exec "''${flags[@]}" -- direnv exec . "$@"
        else
          exec "$DVM_CORE" exec "''${flags[@]}" "$@"
        fi
        '' else ''
        exec "$DVM_CORE" exec "$@"
        ''}
        ;;
      ${agentCases}
      -h|--help|help)
        usage
        ;;
      *)
        echo "Unknown command: $command" >&2
        echo "Run 'dvm --help' for usage." >&2
        exit 1
        ;;
    esac
  '';
}
