# DVM — macOS VM sandbox for coding agents

Sandboxed macOS VM where AI coding agents (Claude Code, Codex) run isolated from the host.
The host manages the VM lifecycle; the guest runs agent workloads.
Communication is over vsock (no network dependency).

## Architecture

```
Host (macOS)                          Guest (macOS VM, Tart)
─────────────                         ─────────────────────
dvm (bash wrapper)                    darvm-agent (Go)
 └─ dvm-core (Swift)                   ├─ gRPC server (vsock :6175)
     ├─ VM lifecycle (Tart)             │   ├─ Exec (bidi streaming, PTY)
     ├─ AgentProxy (:6175)  ──vsock──►  │   ├─ Activate (nix-darwin)
     ├─ VsockDaemonBridge ◄──vsock──    │   ├─ Status, ResolveIP
     │   (:6174, nix daemon)            │   └─ runs as root, execs as UID 501
     ├─ HostCommandBridge               ├─ nix daemon bridge
     │   (:6176, host actions)          │   (unix socket → vsock :6174)
     │   (immutable nix manifest)       └─ dvm-host-cmd (Go, busybox)
     ├─ ControlSocket                       (argv[0] → vsock :6176 → host)
     │   (/tmp/dvm-control.sock)
     └─ VirtioFS mounts                dvm-mount-store (sh, baked in image)
        (nix-store, dvm-state,            (mounts nix-store + dvm-state at boot)
         project dirs)                dvm-activator (sh, baked in image)
                                          (WatchPaths trigger → darwin-rebuild)
                                      nix-darwin modules configure guest
```

**Vsock ports:** 6174 (nix daemon bridge), 6175 (gRPC agent), 6176 (host action bridge)

**Boot sequence:** configure → boot → activate (state-file watch) → waitForAgent → mount VirtioFS → running

## Directory layout

```
host/Sources/          Swift host binary (dvm-core)
  Main.swift             CLI entry + Start/Switch/Stop/Exec/SSH/Status commands
  AgentClient.swift      gRPC client wrapper (connects via AgentProxy socket)
  AgentProxy.swift       NIO: unix socket ↔ vsock :6175 proxy
  VsockDaemonBridge.swift  vsock :6174 → host nix daemon socket
  HostCommandBridge.swift  vsock :6176 → host actions (immutable nix manifest)
  ControlSocket.swift    Unix socket for inter-process coordination (status/stop)
  VMConfigurator.swift   VZ framework config (CPU, RAM, mounts, vsock)
  VMRunner.swift         Tart VM start/stop
  Config.swift           ~/.config/dvm/config.toml loader
  MountConfig.swift      VirtioFS mount types (mirror, home, exact)

guest/agent/           Go guest agent (darvm-agent)
  cmd/main.go            Entry point (--run-rpc, --run-bridge flags)
  internal/rpc/          gRPC handlers: exec, activate, status, resolveip
  internal/vsock/        AF_VSOCK listener/conn for Go
  internal/bridge/       nix daemon socket → vsock bridge

guest/host-cmd/        Go binary forwarding host actions to host (busybox pattern)
guest/image-minimal/   Packer template for minimal base image (Nix + mount + activator)
guest/modules/         nix-darwin modules for guest configuration
  guest-plumbing.nix     Core: launchd daemons, nix socket wiring, user setup
  prelude.nix            Defaults: zsh, starship, git, common tools
  ai-agents.nix          DVM adapter: imports shared ai-agents Hjem module and derives home mounts
  agents.nix             Agent runtime module umbrella (imports ai-agents + per-agent wrappers)
  claude.nix             Claude runtime wrapper + guest-only flags
  codex.nix              Codex runtime wrapper + guest-only flags
  pi.nix                 Pi runtime wrapper + guest-only args/auto-resume
  direnv.nix             Auto-activate project devShells

nix/
  mk-darvm.nix           Evaluate darwinSystem for dvmConfigurations
  mk-dvm-wrapper.nix     Thin CLI wrapper (flake resolution, runtime nix build)
  create-base-vm.nix     Packer-based base image creation script

proto/agent.proto      gRPC service definition (Exec, ResolveIP, Activate, Status)
```

## Build and dev workflow

Requires: Xcode (Swift 6.0+), Go, Nix, Tart, just

```sh
just build              # Build dvm-core + agent + host-cmd (debug)
just build release      # Release build
just proto              # Regenerate Go code from proto/agent.proto
just dvm start          # Build + run dvm
just dvm switch         # Rebuild nix-darwin config and activate in guest
just dvm exec -- ls /   # Run command in guest
just install            # Install to nix profile
just logs               # Stream guest agent logs
```

**DVM_CORE** env var overrides the dvm-core binary path (set automatically by devShell).

**Validating nix module changes:** Use `nix eval` to spot-check module outputs before a full build cycle. For example: `nix eval --impure --json .#dvmConfigurations.default.config.dvm.capabilities` to verify capability definitions, `nix eval --json .#dvmConfigurations.default.config.hjem.users.admin.ai.renderedAgents` to inspect shared agent rendering, or `nix eval --impure .#dvmConfigurations.default.config.system.build.toplevel` to check the closure builds.

**Base image** is content-addressed: `darvm-<hash>` where hash covers `guest/image-minimal`. Changes to agent, host-cmd, or modules never trigger an image rebuild — they're delivered by nix-darwin activation.

## End-to-end testing

Prefer the cheapest verification that matches the risk. Use `nix eval`, narrow
builds, and direct inspection of generated scripts/config first; reserve full
end-to-end flows for changes that actually require activation/runtime proof.

After changes to host code, guest modules, or the Packer template, run through
these checks using the same commands a user would.

**0. Build and install:**
```sh
just build && just install
# Installs dvm to the nix profile. Use `dvm` directly for all commands below.
```

**1. First-time setup (image build):**
```sh
dvm init
# Expect: "Base VM 'darvm-<hash>' is up to date." if image exists,
# or a Packer build if the template changed.
# Tip: set BASE_IMAGE=tahoe-base to skip the 25GB OCI download.
```

**2. Start the VM:**
```sh
dvm start
# Expect: "Building system closure" → "Activation succeeded" →
# "Guest agent connected" → mounts → "VM running"
# Ctrl-C to stop when done verifying.
```

**3. Switch on running VM:**
```sh
# In another terminal, with the VM running:
dvm switch
# Expect: "Building system closure" → "Switch complete."
```

**4. Exec and catch-all forwarding:**
```sh
dvm exec -- echo hello     # Expect: "hello"
dvm echo hello             # Same — unrecognized commands forward to guest
```

**5. Subsequent boot (no activation):**
```sh
# Stop the VM (Ctrl-C), then start again:
dvm start
# Expect: no "Activation" phase. Agent connects within ~30s.
```

**6. Image stability after code changes:**
```sh
# After changing agent/module/host code (not guest/image-minimal/):
dvm init
# Expect: "Base VM 'darvm-<hash>' is up to date." (no rebuild)
```

**Notes:**
- The credential proxy (netstack sidecar) is always-on. Credentials are
  pushed at exec time from `.dvm/credentials.toml` in the working directory,
  the `--credentials` flag, or `DVM_CREDENTIALS` env var.
- `dvm switch` works even if run while the VM is still booting — it waits.
- State files are at `~/.local/state/dvm/` (readable from host during activation).

## Agent workflow notes

**`dvm start` is a blocking foreground process.** It runs the VM until Ctrl-C.
When running from an agent context, use `run_in_background: true` and check
`dvm status --json` once after 30-60s. **Never poll in a tight loop** — if the
VM failed to start, the status will never change and the loop blocks forever.

**`dvm init --confirm` for non-interactive use.** Without a TTY, `dvm init`
aborts at prompts. Pass `--confirm` (or `-y`) to skip prompts. Packer
plugins persist in `~/.packer.d/` across reboots.

**Temporary guest services for tests/harnesses must use launchd, not `nohup ... &` through `dvm exec`.** `dvm exec` is a foreground command channel; shell backgrounding and detachment semantics are brittle across non-interactive shells, TTY-less sessions, and root-vs-user boundaries. For any guest helper that must survive beyond one exec call, create a temporary `LaunchDaemon`, start it with `launchctl bootstrap`/`kickstart`, verify readiness with the same privileged probe as the real code path (for example `sudo lsof` if the agent's status scan runs as root), and clean it up with `launchctl bootout`.

## Conventions

- **Swift 6 strict concurrency.** `@MainActor` for VZ framework types, `@unchecked Sendable` only where unavoidable (delegates).
- **Go for guest binaries.** Cross-compiled with `GOOS=darwin GOARCH=arm64`.
- **Parse at the boundary.** Typed wrappers: `GuestIP`, `NixStorePath`, `AbsolutePath`, `MountTag`. Validate at construction, trust internally.
- **Agent runs as root, execs as UID 501.** The admin user may be renamed; resolved dynamically via `user.LookupId("501")`.
- **VZVirtioSocketConnection must be retained** for the full session. Dealloc tears down the vsock channel immediately.
- **gRPC client lifecycle:** Don't use `withGRPCClient` — HTTP/2 graceful shutdown hangs through the NIO byte proxy. Use manual `client.beginGracefulShutdown()` + `cancelAll()`.
- **`dvm switch` must be sufficient.** All config changes from the nix closure must take effect via `dvm switch` alone, without restarting the VM. If a host component caches closure state at startup, it must support reloading via the control socket.

## Security notes

- **Host actions use an immutable nix manifest.** `dvm.capabilities` in guest-plumbing.nix maps action names to handler scripts in `/nix/store/`. The manifest is generated at nix eval time and passed to dvm-core via `--capabilities`. The manifest path and all handler paths must be in `/nix/store/` — validated at load time. No mutable config, no PATH resolution, no runtime modification.
- **Handler execution is sandboxed.** Handlers run with a scrubbed environment (`PATH=/usr/bin:/bin` only), `cwd=/`, 10s timeout, 64KB payload cap.
- **Vsock has no caller authentication.** Any process in the guest can connect to any vsock port.

## Tracked work

See `.beans/` for open items. Key ones:
- `nix-darvm-0ws0`: Built-in notification support
