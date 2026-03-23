---
# nix-darvm-r8km
title: First-class Xcode support in guest VM
status: completed
type: feature
priority: normal
created_at: 2026-03-22T18:00:00Z
updated_at: 2026-03-23T10:15:00Z
---

Guest VM only has Command Line Tools — no full Xcode. iOS dev tools (Capacitor, CocoaPods) need `xcodebuild` which requires Xcode.app.

## Problem

`pod install` fails with: `xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance`

## Post-mount setup steps discovered

Mounting Xcode.app via VirtioFS is necessary but not sufficient. Four additional
steps are needed before iOS tooling works:

1. **`xcode-select -s`** — point active developer dir to the mounted Xcode
2. **`xcodebuild -license accept`** — accept Xcode license (CocoaPods checks this)
3. **`xcodebuild -runFirstLaunch`** — installs CoreSimulator.framework and other
   first-launch packages into `/Library/Developer/PrivateFrameworks/`. Without this,
   `xcodebuild` fails with `dlopen` errors for `IDESimulatorFoundation.framework`
4. **`DEVELOPER_DIR` env var** — `xcrun` can't find SDKs without it (even after
   `xcode-select -s`). Needed for `xcrun simctl`, SDK resolution, etc.
5. **Simulator runtimes** — guest CoreSimulatorService doesn't auto-discover
   host runtimes even with `/Library/Developer/CoreSimulator` mounted.
   **Fix:** symlink the `.simruntime` bundle into `Profiles/Runtimes/` on the
   **host** side (guest can't write to VirtioFS mounts due to UID mapping).
   Then guest CoreSimulatorService discovers it automatically — all device types
   appear, no download needed.

Steps 1-5 are all automatable.

## Workaround (works now, no code changes)

1. Add to `~/.config/dvm/config.toml`:
   ```toml
   [mounts]
   mirror = ["/Applications/Xcode.app", "/Library/Developer/CoreSimulator"]
   ```
2. On **host** (guest can't write to VirtioFS mounts):
   ```
   sudo mkdir -p /Library/Developer/CoreSimulator/Profiles/Runtimes
   sudo ln -s '/Library/Developer/CoreSimulator/Volumes/iOS_23D8133/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.3.simruntime' '/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.3.simruntime'
   ```
3. In guest:
   ```
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   sudo xcodebuild -runFirstLaunch
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   ```

## Proper solution: two pieces

### 1. Add `dvm.mounts.mirror` to module system

Parallel to existing `dvm.mounts.home` in guest-plumbing.nix:
- New option: `dvm.mounts.mirror` (list of absolute paths)
- Materialize to `/etc/dvm/mirror-mounts.json`
- Wrapper reads it and passes `--dir` flags to dvm-core (same pattern as home-mounts.json in mk-dvm-wrapper.nix lines 126-131)

### 2. Add `xcode.nix` guest module

- `dvm.xcode.enable = true`
- Adds `/Applications/Xcode.app` to `dvm.mounts.mirror`
- Activation script runs: `xcode-select -s`, `xcodebuild -license accept`,
  `xcodebuild -runFirstLaunch` (idempotent — skips if already done)
- Sets `DEVELOPER_DIR` globally via `environment.variables`
- Simulator runtimes: mount `/Library/Developer/CoreSimulator` + host-side
  symlink of `.simruntime` bundles into `Profiles/Runtimes/`. The symlink
  must be created on the host (guest can't write to VirtioFS due to UID mapping).
  The `xcode.nix` module could generate a host-side setup script or capability.
- Optionally adds CocoaPods to systemPackages

### Open questions

- Does `xcodebuild -runFirstLaunch` persist across reboots? The files it installs
  go to `/Library/Developer/PrivateFrameworks/` which is on the VM disk image, so
  likely yes. But the license acceptance state may need investigation.
- VirtioFS performance with Xcode.app (~35GB bundle) — is it acceptable for builds,
  or do we need to consider copying to local disk?
- The runtime symlink is host-side setup that can't be done from the guest or
  from nix-darwin activation. Needs either a host-side setup script, a dvm
  capability/hook, or documentation.
