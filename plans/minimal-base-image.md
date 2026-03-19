# Minimal Base Image + Bootstrap

## Problem

The current base image contains mutable state: agent binaries baked in by
Packer, hot-swapped via SSH, drifting from what nix-darwin declares. You're
never sure what's actually running in the guest. Image rebuilds are slow (~5
min) and triggered by source changes that shouldn't require them.

## Goal

Make the guest state fully reproducible from the nix config. The base image is
an immutable foundation — macOS + Nix, nothing else. Everything above it is
declarative: `dvm switch` is the only way to change guest state, and what's
running always matches what nix describes. No drift, no "did I deploy the
latest agent?", no hot-swap workflows to distrust.

Day-to-day iteration is: edit code → `just build` → `dvm switch`. No image
rebuild.

## Minimal Base Image

Contains only:

- macOS (Cirrus Labs tahoe-base)
- Nix (Determinate installer)
- Passwordless sudo
- `/etc/zshenv` rename (for nix-darwin to manage)
- sshd (already in base image)
- VirtioFS mount script + LaunchDaemon (mounts `/nix/store` and `dvm-state`)
- Activator LaunchDaemon with `WatchPaths` trigger

The mount script and activator are required because macOS has no way to
automount VirtioFS at a custom path (see DECISION_RECORD.md DR-002) and
activation must survive agent restarts (see DR-007).

**Not in the image:** agent binary, host-cmd, agent LaunchDaemons, bridge.
All delivered by nix-darwin.

## Activation Model

One activator daemon, two triggers. The activator is a launchd-managed
`WatchPaths` daemon baked into the image. It never restarts during activation
because it's independent of the agent.

### How it works

**Baked into the image:**

1. `/usr/local/bin/dvm-activator` — shell script (~15 lines):
   - Reads closure path from `/var/run/dvm-state/closure-path`
   - Runs `darwin-rebuild activate`
   - Writes state files: `running` → `done`/`failed` + `exit-code` + `activation.log`

2. `com.dvm.activator.plist` — LaunchDaemon:
   - `WatchPaths: ["/var/run/dvm-state/trigger"]`
   - launchd runs the activator whenever the trigger file is touched

3. `/usr/local/bin/dvm-mount-store` — mount script (~10 lines):
   - Mounts `nix-store` on `/nix/store`
   - Mounts `dvm-state` on `/var/run/dvm-state`

### First boot (no agent exists)

1. Host writes closure path + activation script to a host-side temp dir
2. Host attaches the dir as VirtioFS device `dvm-state` before VM boot
3. VM boots → mount script mounts `/nix/store` and `/var/run/dvm-state`
4. Mount script touches `/var/run/dvm-state/trigger`
5. Activator daemon fires (WatchPaths), reads closure path, runs activation
6. Activation installs the agent, all services, everything via nix-darwin
7. Host watches state files on host filesystem (VirtioFS = instant visibility)
8. Agent comes up on vsock:6175. Host connects via gRPC.

No SSH needed. No network dependency. Works with NAT or credential proxy.

### Runtime switch (agent is running)

1. Host builds new nix-darwin closure
2. Host writes closure path to the state dir via agent's gRPC Exec:
   `agentClient.exec(["sh", "-c", "echo <path> > /var/run/dvm-state/closure-path && touch /var/run/dvm-state/trigger"])`
3. Activator daemon fires, runs activation
4. Agent may restart (nix-darwin manages it) — doesn't matter, the activator
   is a separate launchd service
5. Host catches gRPC disconnect, reconnects when agent comes back
6. Host reads state files to confirm success

Same activator, same state files, different trigger mechanism.

### Subsequent boots (agent already installed)

1. Mount script runs, mounts `/nix/store` and `/var/run/dvm-state`
2. No activation needed (nix-darwin state persists across reboots)
3. Agent starts from `/nix/store` (KeepAlive retries until mount ready)
4. Host connects via vsock/gRPC

## State Machine

Per-activation state tracked via files in `/var/run/dvm-state/<run-id>/`:

```
init         → activation requested (closure path written)
running      → activator picked it up and is executing
done         → activation succeeded
failed       → activation failed
exit-code    → numeric exit code
activation.log → stdout/stderr from darwin-rebuild
```

Atomic renames for transitions. Per-run directory avoids stale state confusion.
Host polls state files — on first boot via host filesystem (VirtioFS share),
on runtime switch via gRPC exec or direct file read.

## Observability

- Mount script logs to `/var/log/dvm-boot.log`
- Activator logs to `/var/run/dvm-state/<run-id>/activation.log`
  (visible on host filesystem immediately via VirtioFS)
- Agent logs to `/var/log/darvm-agent.log`
- All state transitions are file-based and inspectable

## Open Questions

### Q1: Agent boot ordering — RESOLVED

The agent binary lives in `/nix/store`. launchd doesn't guarantee ordering
between LaunchDaemons, so the agent may start before the mount is ready.

**Decision:** Rely on launchd `KeepAlive` retries. The agent binary doesn't
exist until the mount completes; launchd retries automatically.

**Observability:**
- Agent checks `/nix/store` availability at startup and logs clearly
- Agent LaunchDaemon plist routes stdout/stderr to `/var/log/darvm-agent.log`

### Q2: Self-restart during switch — RESOLVED

**Decision:** Use the WatchPaths activator daemon (see Activation Model above).
The activator is independent of the agent — agent restarts don't affect it.
No `nohup`, no orphan process management, no `AbandonProcessGroup` needed.

### Q3: First boot detection — RESOLVED

**Decision:** Not needed. The VirtioFS init hook works on every first boot
regardless of whether the agent exists. The host writes the closure path and
touches the trigger before booting. If the agent is already installed (not
first boot), the host uses the agent's exec to touch the trigger instead.
The activator doesn't care who triggered it.

### Q4: WatchPaths reliability — VERIFIED

Tested 2026-03-19 on `darvm-minimal` image:
- WatchPaths fires on file modification (touch existing file) ✓
- Works before nix-darwin (plist loaded manually via launchctl) ✓
- Second touch while running: launchd queues and runs after first completes ✓

## Success Criteria

The implementation is done when all of these pass:

### SC-1: Fresh image boots and activates via VirtioFS hook
- Build the minimal image (`just init`)
- Run `dvm start` for the first time (fresh image, no prior activation)
- The VM boots, mounts nix-store, activator fires, nix-darwin activates
- Agent comes up on vsock
- `dvm exec -- true` succeeds
- No SSH used at any point

### SC-2: Works with credential proxy from first boot
- Configure `.dvm/credentials.toml` before first boot
- `dvm start` uses FileHandle attachment (not NAT)
- Activation still completes (no SSH/NAT dependency)
- Credential injection works after activation

### SC-3: `dvm switch` works on running VM
- VM is running with agent connected
- Change nix-darwin config
- Run `dvm switch`
- Activation completes even though agent restarts mid-activation
- New agent comes up, host reconnects
- `dvm exec -- true` succeeds after switch

### SC-4: Subsequent boot works without re-activation
- Stop VM, start again
- Mount script runs, agent starts from nix store
- No activation triggered (no trigger file present)
- `dvm exec -- true` succeeds within 30s of boot

### SC-5: Image never rebuilds for code changes
- Change guest agent source code
- Run `just build && dvm switch`
- No image rebuild prompted
- New agent binary deployed via nix-darwin

### SC-6: Observable failure modes
- Intentionally break the closure path → activator logs clear error
- Kill the VM mid-activation → stale state doesn't confuse next boot
- Agent fails to start after mount → logs explain why

## Prior Art

- avm-swift spike: bootstrap proxy discussion (memex `019cf714`)
- Codex review: identified boot ordering + self-restart concerns
- Oracle review: identified launchd process group kill behavior with `nohup`
- Both Codex and Oracle endorsed the split transport / unified execution model

## Image Hash

Content-address hash covers only the Packer template
(`guest/image/darvm-base.pkr.hcl`). Changes to `guest/agent`, `guest/host-cmd`,
or `guest/modules` never trigger an image rebuild.
