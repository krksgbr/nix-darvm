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
     │   (:6176, guest→host cmds)       │   (unix socket → vsock :6174)
     ├─ ControlSocket                   └─ dvm-host-cmd (Go, busybox)
     │   (/tmp/dvm-control.sock)            (argv[0] → vsock :6176 → host)
     └─ VirtioFS mounts                dvm-mount-store (sh, baked in image)
        (nix-store, dvm-state,            (mounts nix-store + dvm-state at boot)
         project dirs)                dvm-activator (sh, baked in image)
                                          (WatchPaths trigger → darwin-rebuild)
                                      nix-darwin modules configure guest
```

**Vsock ports:** 6174 (nix daemon bridge), 6175 (gRPC agent), 6176 (host command bridge)

**Boot sequence:** configure → boot → activate (state-file watch) → waitForAgent → mount VirtioFS → running

## Directory layout

```
host/Sources/          Swift host binary (dvm-core)
  Main.swift             CLI entry + Start/Switch/Stop/Exec/SSH/Status commands
  AgentClient.swift      gRPC client wrapper (connects via AgentProxy socket)
  AgentProxy.swift       NIO: unix socket ↔ vsock :6175 proxy
  VsockDaemonBridge.swift  vsock :6174 → host nix daemon socket
  HostCommandBridge.swift  vsock :6176 → execute allowed commands on host
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

guest/host-cmd/        Go binary forwarding commands to host (busybox pattern)
guest/image-minimal/   Packer template for minimal base image (Nix + mount + activator)
guest/modules/         nix-darwin modules for guest configuration
  guest-plumbing.nix     Core: launchd daemons, nix socket wiring, user setup
  prelude.nix            Defaults: zsh, starship, git, common tools
  agents.nix             Agent option declarations (dvm.agents.<name>)
  claude.nix             Claude Code agent config
  codex.nix              Codex agent config
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

**Base image** is content-addressed: `darvm-<hash>` where hash covers `guest/image-minimal`. Changes to agent, host-cmd, or modules never trigger an image rebuild — they're delivered by nix-darwin activation.

## Conventions

- **Swift 6 strict concurrency.** `@MainActor` for VZ framework types, `@unchecked Sendable` only where unavoidable (delegates).
- **Go for guest binaries.** Cross-compiled with `GOOS=darwin GOARCH=arm64`.
- **Parse at the boundary.** Typed wrappers: `GuestIP`, `NixStorePath`, `AbsolutePath`, `MountTag`. Validate at construction, trust internally.
- **Agent runs as root, execs as UID 501.** The admin user may be renamed; resolved dynamically via `user.LookupId("501")`.
- **VZVirtioSocketConnection must be retained** for the full session. Dealloc tears down the vsock channel immediately.
- **gRPC client lifecycle:** Don't use `withGRPCClient` — HTTP/2 graceful shutdown hangs through the NIO byte proxy. Use manual `client.beginGracefulShutdown()` + `cancelAll()`.

## Security notes

- **Host command allowlist** (`~/.config/dvm/config.toml` `[host].commands`) is the security boundary for guest→host command execution. Do NOT mount `~/.config/dvm` writable in the guest.
- **Vsock has no caller authentication.** Any process in the guest can connect to any vsock port.
- Config-based allowlist is a known weakness — migration to nix config is tracked in beans (`nix-darvm-xuus`).

## Tracked work

See `.beans/` for open items. Key ones:
- `nix-darvm-xuus`: Migrate config.toml to nix (eliminate mutable config attack surface)
- `nix-darvm-0ws0`: Built-in notification support (blocked by xuus)
