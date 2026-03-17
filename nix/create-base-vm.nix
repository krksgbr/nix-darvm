# Produces a shell script that creates the dvm base VM image via Packer + Tart.
# Checks if the VM already exists, prompts before expensive operations, pulls
# the OCI base image, and runs the Packer template.
#
# The base image includes: Determinate Nix + sshd + passwordless sudo +
# darvm-agent (built from source inside the VM using nix).
# nix-darwin and agents are layered on by `dvm switch`.

{ nixpkgs, system ? "aarch64-darwin" }:

{
  defaultBaseImage ? "ghcr.io/cirruslabs/macos-tahoe-base@sha256:593df8dcf9f00929c9e8f19e47793657953ba14112830efa7aaccdd214410093",
}:

let
  lib = nixpkgs.lib;
  pkgs = nixpkgs.legacyPackages.${system};
  pkgsWithPacker = import nixpkgs {
    inherit system;
    config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "packer" ];
  };
  inherit (lib) escapeShellArg;

  # Content-addressed tag from image inputs. Changes when agent source
  # or Packer template changes, triggering a rebuild prompt.
  imageInputsHash = builtins.substring 0 8 (builtins.hashString "sha256"
    "${../guest/agent}:${../guest/host-cmd}:${../guest/image}");
  vmName = "darvm-${imageInputsHash}";
in
pkgs.writeShellApplication {
  name = "dvm-create-vm";
  runtimeInputs = with pkgs; [ coreutils python3 ];
  meta.mainProgram = "dvm-create-vm";
  text = ''
    set -euo pipefail

    TEMPLATE_DIR=${escapeShellArg "${../guest/image}"}
    AGENT_SRC_DIR=${escapeShellArg "${../guest/agent}"}
    HOST_CMD_SRC_DIR=${escapeShellArg "${../guest/host-cmd}"}
    TEMPLATE="$TEMPLATE_DIR/darvm-base.pkr.hcl"
    PACKER=${escapeShellArg "${pkgsWithPacker.packer}/bin/packer"}
    DEFAULT_BASE_IMAGE=${escapeShellArg defaultBaseImage}
    VM_NAME=${escapeShellArg vmName}
    PACKER_CONFIG_DIR="''${PACKER_CONFIG_DIR:-/tmp/dvm-packer-config}"
    PACKER_CACHE_DIR="''${PACKER_CACHE_DIR:-/tmp/dvm-packer-cache}"
    XDG_CACHE_HOME="''${XDG_CACHE_HOME:-/tmp/dvm-xdg-cache}"
    BASE_IMAGE="''${BASE_IMAGE:-$DEFAULT_BASE_IMAGE}"
    export VM_NAME BASE_IMAGE

    if ! command -v tart >/dev/null 2>&1; then
      echo "ERROR: tart is required but not found in PATH." >&2
      echo "Install it with: brew install tart" >&2
      exit 1
    fi

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
      printf "Delete old image and rebuild? [Y/n] "
      read -r answer </dev/tty || answer="y"
      case "$answer" in
        [nN]*) echo "Aborted."; exit 1 ;;
      esac
      for vm in $STALE; do
        echo "Deleting $vm..."
        tart delete "$vm"
      done
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
    printf "  \xe2\x86\x92 Build agent        ~30s\n"
    echo ""
    printf "Proceed? [Y/n] "
    read -r answer </dev/tty || answer="y"
    case "$answer" in
      [nN]*) echo "Aborted."; exit 1 ;;
    esac

    # Pull base image if not local
    if [ "$HAS_BASE_IMAGE" = false ]; then
      echo "Pulling base image: $BASE_IMAGE"
      tart pull "$BASE_IMAGE"
    fi

    export PACKER_CONFIG_DIR PACKER_CACHE_DIR XDG_CACHE_HOME

    "$PACKER" init "$TEMPLATE_DIR"
    "$PACKER" validate \
      -var "base_image=$BASE_IMAGE" \
      -var "vm_name=$VM_NAME" \
      -var "dvm_agent_src=$AGENT_SRC_DIR" \
      -var "dvm_host_cmd_src=$HOST_CMD_SRC_DIR" \
      "$TEMPLATE"
    "$PACKER" build \
      -var "base_image=$BASE_IMAGE" \
      -var "vm_name=$VM_NAME" \
      -var "dvm_agent_src=$AGENT_SRC_DIR" \
      -var "dvm_host_cmd_src=$HOST_CMD_SRC_DIR" \
      "$TEMPLATE"

    echo "Base VM '$VM_NAME' created successfully."
    echo "$VM_NAME"
  '';
}
