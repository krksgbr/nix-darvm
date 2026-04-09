# mkDvmWrapper — build the thin dvm CLI wrapper.
#
# The wrapper resolves a flake at runtime, calls `nix build` to produce
# the system closure, and orchestrates dvm-core. It carries no baked-in
# closure — just the dvm-core binary, create-vm script, and flake resolution logic.

{
  nixpkgs,
  system ? "aarch64-darwin",
}:

{
  dvm-core,
  dvm-netstack,
  dvm-create-vm,
  dvmFlakeRef, # self.outPath — used for minimal config fallback
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (pkgs) lib;
  inherit (lib) escapeShellArg;

  imageInputsHash = builtins.substring 0 8 (builtins.hashString "sha256" "${../guest/image-minimal}");
  vmName = "darvm-${imageInputsHash}";
in
pkgs.writeShellApplication {
  name = "dvm";
  runtimeInputs = [ dvm-core ];
  meta.mainProgram = "dvm";
  text = ''
    set -euo pipefail

    DVM_CORE="''${DVM_CORE:-${escapeShellArg "${dvm-core}/bin/dvm-core"}}"
    export DVM_NETSTACK="''${DVM_NETSTACK:-${escapeShellArg "${dvm-netstack}/bin/dvm-netstack"}}"
    CREATE_VM=${escapeShellArg "${dvm-create-vm}/bin/dvm-create-vm"}
    DVM_FLAKE_REF=${escapeShellArg dvmFlakeRef}
    FLAKE_ARG=""
    CONTROL_SOCKET="/tmp/dvm-control.sock"

    # Query VM phase from the control socket. Returns empty if unreachable.
    vm_phase() {
      "$DVM_CORE" status --json 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("phase",""))' 2>/dev/null \
        || true
    }

    # Fail fast if there's no VM process at all (control socket absent).
    # Used by switch, which has its own wait loop for boot phases.
    require_vm_process() {
      if [ ! -S "$CONTROL_SOCKET" ]; then
        echo "Error: VM not running. Start it with: dvm start" >&2
        exit 1
      fi
    }

    # Require the VM to be in the running phase. Gives informative errors
    # for every other state so the user knows exactly what's happening.
    require_vm() {
      require_vm_process
      local phase
      phase=$(vm_phase)
      case "$phase" in
        running) return 0 ;;
        stopped)
          echo "Error: VM is stopped. Start it with: dvm start" >&2
          exit 1 ;;
        failed)
          local error
          error=$("$DVM_CORE" status --json 2>/dev/null \
            | python3 -c 'import json,sys;print(json.load(sys.stdin).get("phaseError","unknown"))' 2>/dev/null \
            || echo "unknown")
          echo "Error: VM failed: $error" >&2
          exit 1 ;;
        "")
          echo "Error: VM not running. Start it with: dvm start" >&2
          exit 1 ;;
        *)
          echo "Error: VM is not ready (phase: $phase). Check: dvm status" >&2
          exit 1 ;;
      esac
    }

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
      if [ -n "$FLAKE_ARG" ]; then
        echo "Flake: $FLAKE_ARG (--flake flag)" >&2
        echo "$FLAKE_ARG"; return
      fi
      # CWD flake.nix — only use if it actually provides dvmConfigurations
      if [ -f "$PWD/flake.nix" ] && nix eval "$PWD#dvmConfigurations" --apply 'x: true' >/dev/null 2>/dev/null; then
        echo "Flake: $PWD (current directory)" >&2
        echo "$PWD"; return
      fi
      # config.toml flake field
      local cfg_flake
      cfg_flake=$("$DVM_CORE" config-get flake 2>/dev/null || true)
      if [ -n "$cfg_flake" ]; then
        echo "Flake: $cfg_flake (config.toml)" >&2
        echo "$cfg_flake"; return
      fi
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

    # Exec a dvm-core command, wrapping with DVM_CREDENTIAL_PROVIDER if set.
    # Used for commands that do credential resolution (shell, exec, catch-all).
    # Example: DVM_CREDENTIAL_PROVIDER="fnox exec" causes dvm-core to run
    # inside fnox, which populates the host env with keychain secrets before
    # passthrough credential resolution reads them.
    exec_with_creds() {
      if [ -n "''${DVM_CREDENTIAL_PROVIDER:-}" ]; then
        exec ''${DVM_CREDENTIAL_PROVIDER} "$@"
      else
        exec "$@"
      fi
    }

    build_closure() {
      local flake
      flake=$(resolve_flake)
      local attr
      attr=$(resolve_config_attr "$flake")
      echo "Building system closure..." >&2
      nix build --impure "$flake#$attr" --no-link --print-out-paths
    }

    usage() {
      cat <<USAGE
    dvm — sandboxed macOS VM for coding agents

    Usage: dvm [--flake <path>] <command> [args...]

    Commands:
      init [--confirm]  Create the base VM image (first-time setup)
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
      "$CREATE_VM" "$@"
    }

    cmd_start() {
      # Ensure base VM exists.
      if ! tart list --format json 2>/dev/null | python3 -c 'import json,sys; vms=json.load(sys.stdin); sys.exit(0 if any(v["Name"].startswith("darvm-") for v in vms) else 1)'; then
        "$CREATE_VM"
      fi

      # Find the actual darvm-* VM name.
      ACTUAL_VM=$(tart list --format json | python3 -c 'import json,sys;vms=json.load(sys.stdin);ms=[v["Name"]for v in vms if v["Name"].startswith("darvm-")];print(ms[0])if ms else None' 2>/dev/null)
      ACTUAL_VM="''${ACTUAL_VM:-${escapeShellArg vmName}}"

      # Warn if the running image is outdated. An image built from an older
      # guest/image-minimal may be incompatible with this version of dvm-core
      # (e.g., the boot script expects infrastructure that no longer exists).
      # Run 'dvm init' to rebuild.
      if [ "$ACTUAL_VM" != ${escapeShellArg vmName} ]; then
        echo "Warning: VM image '$ACTUAL_VM' is outdated (current: ${escapeShellArg vmName})."
        echo "         The boot script may be incompatible with this version of dvm-core."
        echo "         Run 'dvm init' to rebuild the image."
      fi

      # Build closure from user's flake
      CLOSURE=$(build_closure)
      echo "Closure: $CLOSURE"

      # Extract home-dir mounts from the closure
      HOME_MOUNT_FLAGS=""
      if [ -f "$CLOSURE/etc/dvm/home-mounts.json" ]; then
        for dir in $(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))))' "$CLOSURE/etc/dvm/home-mounts.json" 2>/dev/null); do
          HOME_MOUNT_FLAGS="$HOME_MOUNT_FLAGS --home-dir $HOME/$dir"
        done
      fi

      # Extract read-only system mounts from the closure
      SYSTEM_MOUNT_FLAGS=""
      if [ -f "$CLOSURE/etc/dvm/system-mounts.json" ]; then
        for dir in $(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))))' "$CLOSURE/etc/dvm/system-mounts.json" 2>/dev/null); do
          SYSTEM_MOUNT_FLAGS="$SYSTEM_MOUNT_FLAGS --system-dir $dir"
        done
      fi

      # Extract capabilities manifest from the closure
      CAPABILITIES_FLAG=""
      if [ -f "$CLOSURE/etc/dvm/capabilities.json" ]; then
        CAPABILITIES_FLAG="--capabilities $CLOSURE/etc/dvm/capabilities.json"
      fi

      # Start dvm-core with the runtime-built closure
      # shellcheck disable=SC2086
      exec "$DVM_CORE" start --vm-name "$ACTUAL_VM" --system-closure "$CLOSURE" $HOME_MOUNT_FLAGS $SYSTEM_MOUNT_FLAGS $CAPABILITIES_FLAG "$@"
    }

    cmd_switch() {
      require_vm_process
      # Wait for VM to be fully running (handles switch during boot).
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
        local phase_display="$phase"
        if [ -z "$phase_display" ]; then
          phase_display="unknown"
        fi
        echo "Error: VM did not reach running state. Current phase: $phase_display" >&2
        exit 1
      fi

      # Build closure from user's flake
      CLOSURE=$(build_closure)
      echo "Closure: $CLOSURE"

      # Trigger activation via the guest's WatchPaths activator
      local RUN_ID="switch-$$"
      local STATE_DIR="$HOME/.local/state/dvm"
      local LOG_FILE="$STATE_DIR/run.log"

      # Snapshot log offset before triggering — only stream lines from this switch.
      local LOG_OFFSET
      LOG_OFFSET=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ' || echo 0)

      echo "Activating..."
      "$DVM_CORE" exec --no-credentials -- sudo sh -c "printf '%s' '$CLOSURE' > /var/run/dvm-state/closure-path; printf '%s' '$RUN_ID' > /var/run/dvm-state/run-id; touch /var/run/dvm-state/trigger"

      # Poll via host filesystem (state dir is VirtioFS-mounted).
      # We use wc -c + tail -c rather than `tail -F`: VirtioFS writes from the
      # guest do not trigger kqueue NOTE_WRITE events on the host, so tail -F
      # opens the file and blocks waiting for events that never arrive.
      local ACTIVATOR_STARTED=0
      for _i in $(seq 1 300); do
        # Drain new log bytes
        if [ -f "$LOG_FILE" ]; then
          local SIZE
          SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ' || echo 0)
          if [ "''${SIZE:-0}" -gt "$LOG_OFFSET" ]; then
            tail -c "+$((LOG_OFFSET + 1))" "$LOG_FILE" 2>/dev/null
            LOG_OFFSET="$SIZE"
          fi
        fi
        STATUS=$(cat "$STATE_DIR/$RUN_ID/status" 2>/dev/null || true)
        case "$STATUS" in
          running)
            if [ "$ACTIVATOR_STARTED" -eq 0 ]; then
              ACTIVATOR_STARTED=1
            fi
            ;;
          done)
            # Drain any remaining log bytes
            if [ -f "$LOG_FILE" ]; then
              SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ' || echo 0)
              [ "''${SIZE:-0}" -gt "$LOG_OFFSET" ] && tail -c "+$((LOG_OFFSET + 1))" "$LOG_FILE" 2>/dev/null
            fi
            # Reload host action bridge with new capabilities manifest
            if [ -f "$CLOSURE/etc/dvm/capabilities.json" ]; then
              "$DVM_CORE" reload-capabilities --path "$CLOSURE/etc/dvm/capabilities.json" 2>/dev/null || true
            fi
            echo "Switch complete."; return 0 ;;
          failed|invalid-closure)
            # Drain any remaining log bytes before reporting failure
            if [ -f "$LOG_FILE" ]; then
              SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ' || echo 0)
              [ "''${SIZE:-0}" -gt "$LOG_OFFSET" ] && tail -c "+$((LOG_OFFSET + 1))" "$LOG_FILE" 2>/dev/null
            fi
            echo "Activation failed." >&2
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
        cmd_init "$@"
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
        require_vm
        exec_with_creds "$DVM_CORE" ssh "$@"
        ;;
      exec)
        require_vm
        exec_with_creds "$DVM_CORE" exec "$@"
        ;;
      -h|--help|help)
        usage
        ;;
      *)
        # Catch-all: forward to guest as a command
        require_vm
        exec_with_creds "$DVM_CORE" exec -t -- "$command" "$@"
        ;;
    esac
  '';
}
