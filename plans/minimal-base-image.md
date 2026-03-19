# Minimal Base Image + SSH Bootstrap

## Problem

Every change to `guest/agent` or `guest/host-cmd` triggers a full base image
rebuild (~5 min). The image hash covers source directories that change
frequently during development. This is the biggest friction in the dev loop.

## Goal

The base image should be a stable foundation that almost never needs rebuilding.
Everything else — agent, host-cmd, mount scripts, services — arrives via
nix-darwin `switch`. Day-to-day iteration is: edit code → `just build` →
`dvm switch`. No image rebuild.

## Minimal Base Image

Contains only what the Cirrus Labs macOS base provides plus Nix:

- macOS (Cirrus Labs tahoe-base)
- Nix (Determinate installer)
- Passwordless sudo
- `/etc/zshenv` rename (for nix-darwin to manage)
- sshd (already in base image)

**Not in the image:** agent binary, host-cmd, mount-store script, LaunchDaemons
for agent/bridge. All delivered by nix-darwin.

## Bootstrap Sequence

### First boot (fresh image)

1. VM boots with NAT networking (default — no credential proxy)
2. sshd is running (from base image)
3. Host discovers guest IP via vmnet DHCP lease
4. Host SSHs in:
   a. Mounts `/nix/store` from host via VirtioFS (`mount_virtiofs nix-store /nix/store`)
   b. Runs `darwin-rebuild activate` with the system closure
5. nix-darwin activation installs:
   - Agent binary (in `/nix/store`, symlinked or launched via wrapper)
   - Mount-store LaunchDaemon (script on local disk, persists across reboots)
   - Agent LaunchDaemon
   - Bridge LaunchDaemon
   - host-cmd binary
   - All other services and config
6. Agent is now running on vsock port 6175
7. Host switches from SSH to vsock/gRPC for all further communication

### Subsequent boots

1. mount-store LaunchDaemon runs (installed by nix-darwin on first boot)
2. `/nix/store` available via VirtioFS
3. Agent starts from `/nix/store` (launchd KeepAlive retries until mount ready)
4. Host connects via vsock/gRPC

### Updates

`dvm switch` — rebuild nix-darwin closure on host, activate in guest via gRPC.
Agent restarts with new binary. No image rebuild needed.

## Open Questions

### Q1: Agent launcher wrapper

The agent binary lives in `/nix/store` which isn't available until mount-store
runs. A LaunchDaemon can't point directly at a `/nix/store/...` path because
launchd may try to start it before the mount.

**Options:**
- A: Fixed-path launcher at `/usr/local/bin/darvm-agent-launcher` that polls
  for the mount, then execs the store binary. Installed by nix-darwin activation
  (writes to local disk).
- B: LaunchDaemon with `WatchPaths` or `StartInterval` instead of `RunAtLoad`,
  so it only starts after the mount exists.
- C: The mount-store script explicitly starts the agent after mounting
  (`launchctl bootstrap system ...`).

### Q2: Self-restart during switch

`darwin-rebuild activate` is run via the agent's gRPC Exec. But activation may
restart the agent's own LaunchDaemon. The in-flight exec command could die.

**Options:**
- A: Run activation via SSH instead of gRPC (always available with NAT).
- B: Run activation as a detached background process that survives agent restart
  (`nohup ... &`). Host polls for completion.
- C: The bootstrap proxy idea from the spike: a tiny vsock-to-unix-socket proxy
  baked into the image. Agent restarts don't kill the vsock listener. But this
  adds complexity back to the image.

### Q3: First boot detection

How does the host know it's a first boot (needs SSH bootstrap) vs a subsequent
boot (agent should be available via vsock)?

**Options:**
- A: Always try vsock first, fall back to SSH after timeout. Simple, no state.
- B: Store a "bootstrapped" flag on the host side (e.g., in VM metadata or a
  marker file). Skip SSH if flag exists.
- C: Check if the nix-darwin system profile exists in the guest via SSH before
  deciding.

### Q4: Credential proxy + SSH fallback

With the credential proxy active (VZFileHandleNetworkDeviceAttachment), SSH from
host to guest doesn't work — gVisor doesn't route inbound connections. Vsock is
the only path. If the agent fails to start, the VM is unreachable.

**Current answer:** Acceptable. The credential proxy is opt-in. Without it, NAT
provides SSH fallback. Users who enable the credential proxy accept the narrower
failure mode. Can revisit if this becomes a real problem (e.g., add inbound port
forwarding to the gVisor stack).

## Prior Art

This design was proposed during the avm-swift spike but not implemented due to
time pressure. See memex session `019cf714-0517-7143-b17d-6c190e54ceaf` for:
- The bootstrap proxy architecture (split agent into stable proxy + nix-managed full agent)
- Codex's review identifying boot ordering and self-restart concerns
- The launcher wrapper recommendation

## Image Hash

With this design, the content-address hash covers only the Packer template
(`guest/image/darvm-base.pkr.hcl`). Changes to `guest/agent`, `guest/host-cmd`,
or `guest/modules` never trigger an image rebuild.
