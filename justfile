entitlements := "host/Resources/dvm.entitlements"

# Detect nono sandbox: nested sandbox-exec is forbidden, so SPM needs --disable-sandbox.
swift_sandbox_flag := `sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null && echo '' || echo '--disable-sandbox'`

# Build dvm-core (default: debug). Go binaries are built by nix.
build config="debug":
    cd host && swift build -c {{config}} --scratch-path ../build/swift {{swift_sandbox_flag}}
    codesign --force --sign - --entitlements {{entitlements}} build/swift/{{config}}/dvm-core

# Build dvm-netstack sidecar (Go, host-native)
build-netstack:
    cd host/netstack && go build -o ../../build/dvm-netstack ./cmd/

# Regenerate Go code from proto definitions
proto:
    nix shell nixpkgs#protobuf nixpkgs#protoc-gen-go nixpkgs#protoc-gen-go-grpc -c \
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

# Build and run dvm (e.g. just dvm start, just dvm exec -- ls /)
dvm *args: (build)
    DVM_CORE="$PWD/build/swift/debug/dvm-core" nix run --impure .#dvm -- {{args}}

# Install dvm to nix profile (default: debug, just install release for release)
install config="debug": (build config)
    #!/usr/bin/env bash
    set -euo pipefail
    # Find any existing profile entry that ships bin/dvm (handles renamed packages)
    entry=$(nix profile list --json | python3 -c '
    import json, sys, os
    for name, e in json.load(sys.stdin).get("elements", {}).items():
        for p in e.get("storePaths", []):
            if os.path.isfile(p + "/bin/dvm"):
                print(name); sys.exit(0)
    sys.exit(1)
    ' 2>/dev/null) && {
      echo "Replacing profile entry: $entry"
      nix profile remove "$entry"
    }
    nix profile add --impure .#dvm
