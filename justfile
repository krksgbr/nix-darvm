entitlements := "host/Resources/dvm.entitlements"

# Detect nono sandbox: nested sandbox-exec is forbidden, so SPM needs --disable-sandbox.
swift_sandbox_flag := `sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null && echo '' || echo '--disable-sandbox'`

# Build dvm-core (default: debug)
build config="debug": build-netstack
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

# Hot-swap guest agent binary in a running VM (~5s)
deploy-agent: build-agent
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(dvm status --json 2>/dev/null | jq -r '.ip // empty')
    if [ -z "$IP" ]; then echo "VM not running (use: dvm start)"; exit 1; fi

    ASKPASS=$(mktemp /tmp/askpass.XXXX)
    printf '#!/bin/sh\necho admin' > "$ASKPASS"
    chmod 755 "$ASKPASS"
    export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
    SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR admin@$IP"

    echo "Uploading binary..."
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      build/darvm-agent admin@$IP:/tmp/darvm-agent.new

    echo "Restarting agent..."
    $SSH 'sudo launchctl bootout system/com.darvm.agent-rpc 2>/dev/null || true; sleep 1; sudo mv /tmp/darvm-agent.new /usr/local/bin/darvm-agent; sudo chmod 755 /usr/local/bin/darvm-agent; sudo launchctl bootstrap system /Library/LaunchDaemons/com.darvm.agent-rpc.plist'

    rm -f "$ASKPASS"

    BIN="$PWD/build/swift/debug/dvm-core"
    [ -x "$BIN" ] || BIN="$PWD/build/swift/release/dvm-core"
    echo "Waiting for agent..."
    for i in $(seq 1 10); do
      if DVM_CORE="$BIN" nix run --impure .#dvm -- exec -- true 2>/dev/null; then
        echo "Agent is back."
        exit 0
      fi
      sleep 1
    done
    echo "WARNING: agent did not come back within 10s."
    exit 1

# Cross-compile vsock-bridge for macOS arm64
build-vsock-bridge:
    cd guest/image/vsock-bridge && GOOS=darwin GOARCH=arm64 go build -o ../../../build/dvm-vsock-bridge .

# Cross-compile host-cmd shim for macOS arm64
build-host-cmd:
    cd guest/host-cmd && GOOS=darwin GOARCH=arm64 go build -o ../../build/dvm-host-cmd .

# Hot-swap host-cmd binary in a running VM
deploy-host-cmd: build-host-cmd
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(dvm status --json 2>/dev/null | jq -r '.ip // empty')
    if [ -z "$IP" ]; then echo "VM not running (use: dvm start)"; exit 1; fi

    ASKPASS=$(mktemp /tmp/askpass.XXXX)
    printf '#!/bin/sh\necho admin' > "$ASKPASS"
    chmod 755 "$ASKPASS"
    export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0

    echo "Uploading binary..."
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      build/dvm-host-cmd admin@$IP:/tmp/dvm-host-cmd.new

    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      admin@$IP 'sudo mv /tmp/dvm-host-cmd.new /usr/local/bin/dvm-host-cmd && sudo chmod 755 /usr/local/bin/dvm-host-cmd'

    rm -f "$ASKPASS"
    echo "Deployed dvm-host-cmd."

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
    DVM_CORE="$PWD/build/swift/debug/dvm-core" DVM_NETSTACK="$PWD/build/dvm-netstack" nix run --impure .#dvm -- {{args}}

# Install dvm to nix profile (default: debug, just install release for release)
install config="debug": (build config)
    nix profile upgrade --impure dvm 2>/dev/null || CONFIG={{config}} nix profile add --impure .#dvm
