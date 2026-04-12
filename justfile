entitlements := "host/Resources/dvm.entitlements"

# Detect nono sandbox: nested sandbox-exec is forbidden, so SPM needs --disable-sandbox.
swift_sandbox_flag := `sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null && echo '' || echo '--disable-sandbox'`

# Build dvm-core (default: debug). Go binaries are built by nix.
build config="debug":
    cd host && swift build -c {{config}} --scratch-path ../build/swift {{swift_sandbox_flag}}
    codesign --force --sign - --entitlements {{entitlements}} build/swift/{{config}}/dvm-core

# QA dispatch for discoverable VM-backed tests and probes.
test *args:
    ./scripts/qa test {{args}}

probe *args:
    ./scripts/qa probe {{args}}

# Run configured formatters through the flake formatter.
fmt:
    nix fmt

# Run language linters. Defaults to files changed in the current jj changeset;
# pass `--all` to run the full repo checks unconditionally.
lint *args:
    #!/usr/bin/env bash
    set -euo pipefail
    set -- {{args}}
    if [ "$#" -eq 0 ]; then
      nix develop --command bash ./scripts/lint-changes.sh
      exit 0
    fi
    if [ "$#" -eq 1 ] && [ "$1" = "--all" ]; then
      nix build --no-link \
        .#checks.aarch64-darwin.swift-lint \
        .#checks.aarch64-darwin.go-lint-agent \
        .#checks.aarch64-darwin.go-lint-netstack \
        .#checks.aarch64-darwin.nix-lint
      exit 0
    fi
    echo "usage: just lint [--all]" >&2
    exit 1

# Build dvm-netstack sidecar (Go, host-native)
build-netstack:
    cd host/netstack && go build -o ../../build/dvm-netstack ./cmd/

# Regenerate Go code from proto definitions
proto:
    protoc --go_out=guest/agent/gen --go_opt=paths=source_relative \
           --go-grpc_out=guest/agent/gen --go-grpc_opt=paths=source_relative \
           -I proto proto/agent.proto

# Cross-compile guest agent for macOS arm64
build-agent: proto
    cd guest/agent && GOOS=darwin GOARCH=arm64 go build -o ../../build/darvm-agent ./cmd/

# Cross-compile host-cmd shim for macOS arm64
build-host-cmd:
    cd guest/host-cmd && GOOS=darwin GOARCH=arm64 go build -o ../../build/dvm-host-cmd .

# Stream guest agent logs (default: darvm processes, or pass custom predicate)
logs predicate='process BEGINSWITH "darvm"':
    dvm exec -- log stream --style compact --predicate '{{predicate}}'

# Create/rebuild the base VM image (use BASE_IMAGE=tahoe-base to skip OCI pull)
init:
    nix run --impure .#dvm -- init

# Snapshot the current VM image (tart clone). Restore with: just restore
snapshot:
    #!/usr/bin/env bash
    set -euo pipefail
    VM=$(tart list --format json | python3 -c 'import json,sys;vms=json.load(sys.stdin);ms=[v["Name"]for v in vms if v["Name"].startswith("darvm-")];print(ms[0])if ms else sys.exit(1)')
    SNAP="${VM}-snap"
    tart delete "$SNAP" 2>/dev/null || true
    tart clone "$VM" "$SNAP"
    echo "Snapshot: $SNAP (restore with: just restore)"

# Restore from snapshot
restore:
    #!/usr/bin/env bash
    set -euo pipefail
    SNAP=$(tart list --format json | python3 -c 'import json,sys;vms=json.load(sys.stdin);ms=[v["Name"]for v in vms if v["Name"].endswith("-snap")];print(ms[0])if ms else sys.exit(1)')
    VM="${SNAP%-snap}"
    tart delete "$VM" 2>/dev/null || true
    tart clone "$SNAP" "$VM"
    echo "Restored $VM from $SNAP"

# Push image scripts to a running VM without a full image rebuild.
# Edit scripts/dvm-activator or scripts/dvm-mount-store, then run this.
# Uses the VirtioFS state dir as a staging area (no stdin piping needed).
# Restart the VM after pushing to test: just dvm stop && just dvm start
push-image-scripts:
    #!/usr/bin/env bash
    set -euo pipefail
    SCRIPTS_DIR="$HOME/.local/state/dvm/scripts"
    mkdir -p "$SCRIPTS_DIR"
    cp guest/image-minimal/scripts/dvm-activator "$SCRIPTS_DIR/"
    cp guest/image-minimal/scripts/dvm-mount-store "$SCRIPTS_DIR/"
    DVM_CORE="$PWD/build/swift/debug/dvm-core" nix run --impure .#dvm -- exec -- \
        sudo sh -c 'install -m 755 /var/run/dvm-state/scripts/dvm-activator /usr/local/bin/dvm-activator \
                 && install -m 755 /var/run/dvm-state/scripts/dvm-mount-store /usr/local/bin/dvm-mount-store'
    echo "Scripts pushed. Restart to apply: just dvm stop && just dvm start"

# Build and run dvm (e.g. just dvm start, just dvm exec -- ls /)
dvm *args: (build)
    DVM_CORE="$PWD/build/swift/debug/dvm-core" nix run --impure .#dvm -- {{args}}

# Install dvm to nix profile (default: debug, just install release for release)
install config="debug": (build config)
    #!/usr/bin/env bash
    set -euo pipefail
    # Find any existing profile entry for the dvm package
    entry=$(nix profile list --json | jq -r '
      .elements | to_entries[] | select(.value.storePaths[] | endswith("-dvm")) | .key
    ' 2>/dev/null) && [ -n "$entry" ] && {
      echo "Replacing profile entry: $entry"
      nix profile remove "$entry"
    }
    nix profile add --impure .#dvm
