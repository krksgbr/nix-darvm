# Produces a shell script that creates the dvm base VM image via Packer + Tart.
# Checks if the VM already exists, prompts before expensive operations, pulls
# the OCI base image, and runs the Packer template.
#
# The base image is minimal: Determinate Nix + sshd + passwordless sudo +
# VirtioFS mount script + WatchPaths activator. No agent, no host-cmd.
# Everything else is delivered by nix-darwin activation at boot.

{
  nixpkgs,
  system ? "aarch64-darwin",
}:

{
  defaultBaseImage ? "ghcr.io/cirruslabs/macos-tahoe-base@sha256:593df8dcf9f00929c9e8f19e47793657953ba14112830efa7aaccdd214410093",
}:

let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  pkgsWithPacker = import nixpkgs {
    inherit system;
    config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "packer" ];
  };
  inherit (lib) escapeShellArg;

  # Content-addressed tag from image inputs. Only covers the Packer template
  # directory — changes to agent/host-cmd/modules never trigger a rebuild.
  imageInputsHash = builtins.substring 0 8 (builtins.hashString "sha256" "${../guest/image-minimal}");
  vmName = "darvm-${imageInputsHash}";
in
pkgs.writeShellApplication {
  name = "dvm-create-vm";
  runtimeInputs = with pkgs; [
    coreutils
    python3
  ];
  meta.mainProgram = "dvm-create-vm";
  text = ''
        set -euo pipefail

        TEMPLATE_DIR=${escapeShellArg "${../guest/image-minimal}"}
        TEMPLATE="$TEMPLATE_DIR/darvm-minimal.pkr.hcl"
        PACKER=${escapeShellArg "${pkgsWithPacker.packer}/bin/packer"}
        DEFAULT_BASE_IMAGE=${escapeShellArg defaultBaseImage}
        VM_NAME=${escapeShellArg vmName}
        # Packer state dirs. Use ~/.cache paths so plugins persist across reboots.
        # Previous /tmp/ defaults caused plugins to be wiped and re-downloaded,
        # and required manual pre-initialization in non-interactive contexts.
        PACKER_CACHE_DIR="''${PACKER_CACHE_DIR:-$HOME/.cache/dvm/packer-cache}"
        XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache/dvm/xdg-cache}"
        BASE_IMAGE="''${BASE_IMAGE:-$DEFAULT_BASE_IMAGE}"
        export VM_NAME BASE_IMAGE

        # Parse flags
        AUTO_CONFIRM=false
        while [ $# -gt 0 ]; do
          case "$1" in
            --confirm|-y) AUTO_CONFIRM=true; shift ;;
            *) echo "Unknown flag: $1" >&2; exit 1 ;;
          esac
        done

        if ! command -v tart >/dev/null 2>&1; then
          echo "ERROR: tart is required but not found in PATH." >&2
          echo "Install it with: brew install tart" >&2
          exit 1
        fi

        # Interactive prompt helper. Skips prompt when --confirm is passed.
        # Without --confirm and without a TTY, aborts rather than silently
        # proceeding — agents must explicitly opt in with --confirm.
        confirm() {
          if [ "$AUTO_CONFIRM" = true ]; then
            printf "%s (auto-confirmed via --confirm)\n" "$1"
            return 0
          fi
          printf "%s [Y/n] " "$1"
          if [ -t 0 ]; then
            read -r answer
          else
            echo ""
            echo "Error: no TTY available for interactive prompt." >&2
            echo "Use 'dvm init --confirm' to skip prompts." >&2
            return 1
          fi
          case "$answer" in
            [nN]*) return 1 ;;
            *) return 0 ;;
          esac
        }

        # Check if VM with matching hash exists — image is up to date
        if tart list --format json | python3 -c '
    import json, os, sys
    target = os.environ["VM_NAME"]
    vms = json.load(sys.stdin)
    raise SystemExit(0 if any(vm["Name"] == target for vm in vms) else 1)
        '; then
          echo "Base VM '$VM_NAME' is up to date."
          exit 0
        fi

        # Check for stale VMs with old hashes
        STALE=$(tart list --format json | python3 -c '
    import json, sys
    vms = json.load(sys.stdin)
    stale = [vm["Name"] for vm in vms if vm["Name"].startswith("darvm-") and vm["Name"] != "'"$VM_NAME"'"]
    print("\n".join(stale))
        ' || true)
        if [ -n "$STALE" ]; then
          echo "Base image is outdated. Stale VM(s): $STALE"
          if ! confirm "Delete old image and rebuild?"; then
            # Use the stale image instead of aborting.
            STALE_VM=$(echo "$STALE" | head -1)
            echo "Continuing with stale image: $STALE_VM"
            echo "$STALE_VM"
            exit 0
          fi
          # NOTE: VM deletion disabled during credential proxy development.
          # Uncomment when image hash churn settles down.
          # for vm in $STALE; do
          #   echo "Deleting $vm..."
          #   tart delete "$vm"
          # done
          echo "Skipping stale VM deletion (disabled during development)."
        fi

        # Check if OCI base image is cached locally
        HAS_BASE_IMAGE=false
        if tart list --format json | python3 -c '
    import json, os, sys
    target = os.environ["BASE_IMAGE"]
    vms = json.load(sys.stdin)
    raise SystemExit(0 if any(vm["Name"] == target for vm in vms) else 1)
        '; then
          HAS_BASE_IMAGE=true
        fi

        echo "dvm init"
        echo ""
        echo "Set up the macOS sandbox VM for coding agents."
        echo "This runs once. Later, \`dvm start\` usually boots in ~30s."
        echo ""
        echo "Creating base VM..."
        echo ""
        if [ "$HAS_BASE_IMAGE" = true ]; then
          printf "  \xe2\x9c\x93 Base image         cached\n"
        else
          printf "  \xe2\x86\x92 Base image         ~25GB download\n"
        fi
        printf "  \xe2\x86\x92 Install Nix        ~1 min\n"
        echo ""
        if ! confirm "Proceed?"; then
          echo "Aborted."; exit 1
        fi

        # Pull base image if not local
        if [ "$HAS_BASE_IMAGE" = false ]; then
          echo "Pulling base image: $BASE_IMAGE"
          tart pull "$BASE_IMAGE"
        fi

        export PACKER_CACHE_DIR XDG_CACHE_HOME

        "$PACKER" init "$TEMPLATE_DIR"
        "$PACKER" validate \
          -var "base_image=$BASE_IMAGE" \
          -var "vm_name=$VM_NAME" \
          "$TEMPLATE"
        "$PACKER" build \
          -var "base_image=$BASE_IMAGE" \
          -var "vm_name=$VM_NAME" \
          "$TEMPLATE"

        echo "Base VM '$VM_NAME' created successfully."
        echo "$VM_NAME"
  '';
}
