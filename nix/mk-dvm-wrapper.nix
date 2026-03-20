# mkDvmWrapper — build the thin dvm CLI wrapper.
#
# The wrapper resolves a flake at runtime, calls `nix build` to produce
# the system closure, and orchestrates dvm-core. It carries no baked-in
# closure — just the dvm-core binary, create-vm script, and flake resolution logic.

{ nixpkgs, system ? "aarch64-darwin" }:

{
  dvm-core,
  dvm-create-vm,
  dvmFlakeRef,  # self.outPath — used for minimal config fallback
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  lib = pkgs.lib;
  inherit (lib) escapeShellArg;

  imageInputsHash = builtins.substring 0 8 (builtins.hashString "sha256"
    "${../guest/image-minimal}");
  vmName = "darvm-${imageInputsHash}";
in
pkgs.writeShellApplication {
  name = "dvm";
  runtimeInputs = [ dvm-core ];
  meta.mainProgram = "dvm";
  text = ''
    set -euo pipefail

    DVM_CORE="''${DVM_CORE:-${escapeShellArg "${dvm-core}/bin/dvm-core"}}"
    CREATE_VM=${escapeShellArg "${dvm-create-vm}/bin/dvm-create-vm"}
    DVM_FLAKE_REF=${escapeShellArg dvmFlakeRef}
    FLAKE_ARG=""

    # Parse global flags before subcommand
    while [ $# -gt 0 ]; do
      case "$1" in
        --flake) FLAKE_ARG="$2"; shift 2 ;;
        --flake=*) FLAKE_ARG="''${1#--flake=}"; shift ;;
        *) break ;;
      esac
    done

    resolve_flake() {
      # --flake flag (highest priority)
      if [ -n "$FLAKE_ARG" ]; then echo "$FLAKE_ARG"; return; fi
      # CWD flake.nix
      if [ -f "$PWD/flake.nix" ]; then echo "$PWD"; return; fi
      # config.toml flake field
      local cfg_flake
      cfg_flake=$("$DVM_CORE" config-get flake 2>/dev/null || true)
      if [ -n "$cfg_flake" ]; then echo "$cfg_flake"; return; fi
      # Fallback: minimal config from dvm's own flake
      printf '\033[33mWarning: No user flake found. Using minimal default config.\033[0m\n' >&2
      printf '\033[33mTo configure: create a flake with dvmConfigurations.default, or set flake in ~/.config/dvm/config.toml\033[0m\n' >&2
      echo "$DVM_FLAKE_REF"
    }

    # Determine which dvmConfiguration to build.
    # If using the dvm flake's own fallback, build "minimal". Otherwise "default".
    resolve_config_attr() {
      local flake="$1"
      if [ "$flake" = "$DVM_FLAKE_REF" ]; then
        echo "dvmConfigurations.minimal.config.system.build.toplevel"
      else
        echo "dvmConfigurations.default.config.system.build.toplevel"
      fi
    }

    build_closure() {
      local flake
      flake=$(resolve_flake)
      local attr
      attr=$(resolve_config_attr "$flake")
      nix build --impure "$flake#$attr" --no-link --print-out-paths
    }

    usage() {
      cat <<USAGE
    dvm — sandboxed macOS VM for coding agents

    Usage: dvm [--flake <path>] <command> [args...]

    Commands:
      init              Create the base VM image (first-time setup)
      start             Start the VM (runs init if needed)
      stop              Stop the VM
      reboot            Stop and restart the VM
      status            Show VM status
      switch            Rebuild and activate nix-darwin config
      shell             Open interactive shell at \$PWD in the guest
      exec [cmd...]     Run a command in the guest

    Any other command is forwarded to the guest (e.g. dvm claude).

    USAGE
    }

    cmd_init() {
      "$CREATE_VM"
    }

    cmd_start() {
      # Ensure base VM exists. Skip if any darvm-* VM is already available —
      # a stale hash just means guest/image-minimal changed; the existing VM
      # still works and dvm switch delivers the new config via nix-darwin.
      if ! tart list --format json 2>/dev/null | python3 -c 'import json,sys; vms=json.load(sys.stdin); sys.exit(0 if any(v["Name"].startswith("darvm-") for v in vms) else 1)'; then
        "$CREATE_VM"
      fi

      # Find the actual darvm-* VM name
      ACTUAL_VM=$(tart list --format json | python3 -c 'import json,sys;vms=json.load(sys.stdin);ms=[v["Name"]for v in vms if v["Name"].startswith("darvm-")];print(ms[0])if ms else None' 2>/dev/null)
      ACTUAL_VM="''${ACTUAL_VM:-${escapeShellArg vmName}}"

      # Build closure from user's flake
      echo "Building system closure..."
      CLOSURE=$(build_closure)
      echo "Closure: $CLOSURE"

      # Extract home-dir mounts from the closure
      HOME_MOUNT_FLAGS=""
      if [ -f "$CLOSURE/etc/dvm/home-mounts.json" ]; then
        for dir in $(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))))' "$CLOSURE/etc/dvm/home-mounts.json" 2>/dev/null); do
          HOME_MOUNT_FLAGS="$HOME_MOUNT_FLAGS --home-dir $HOME/$dir"
        done
      fi

      # Start dvm-core with the runtime-built closure
      # shellcheck disable=SC2086
      exec "$DVM_CORE" start --vm-name "$ACTUAL_VM" --system-closure "$CLOSURE" $HOME_MOUNT_FLAGS "$@"
    }

    cmd_switch() {
      # Wait for VM to be fully running (handles switch during boot).
      # Empty phase means the control socket doesn't exist yet (still starting).
      local phase=""
      for _w in $(seq 1 120); do
        phase=$("$DVM_CORE" status --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("phase",""))' 2>/dev/null || true)
        case "$phase" in
          running) break ;;
          failed|stopped)
            echo "Error: VM not running. Start it with: dvm start" >&2
            exit 1 ;;
        esac
        sleep 1
      done
      if [ "$phase" != "running" ]; then
        echo "Error: VM did not reach running state. Current phase: ${phase:-unknown}" >&2
        exit 1
      fi

      # Build closure from user's flake
      echo "Building system closure..."
      CLOSURE=$(build_closure)
      echo "Closure: $CLOSURE"

      # Trigger activation via the guest's WatchPaths activator
      local RUN_ID="switch-$$"
      echo "Activating..."
      "$DVM_CORE" exec -- sudo sh -c "printf '%s' '$CLOSURE' > /var/run/dvm-state/closure-path; printf '%s' '$RUN_ID' > /var/run/dvm-state/run-id; touch /var/run/dvm-state/trigger"

      # Poll via host filesystem (state dir is VirtioFS-mounted)
      local STATE_DIR="$HOME/.local/state/dvm"
      echo "Waiting for activation..."
      for _i in $(seq 1 300); do
        STATUS=$(cat "$STATE_DIR/$RUN_ID/status" 2>/dev/null || true)
        case "$STATUS" in
          done) echo "Switch complete."; return 0 ;;
          failed|invalid-closure)
            echo "Activation failed:" >&2
            cat "$STATE_DIR/$RUN_ID/activation.log" >&2 || true
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
        exec "$DVM_CORE" exec "$@"
        ;;
      -h|--help|help)
        usage
        ;;
      *)
        # Catch-all: forward to guest as a command
        exec "$DVM_CORE" exec -t -- "$command" "$@"
        ;;
    esac
  '';
}
