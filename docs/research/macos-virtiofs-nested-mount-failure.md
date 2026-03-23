# macOS VirtioFS nested mount failure

Date: 2026-03-23

## Summary

Mounting a VirtioFS device at a path inside another VirtioFS mount on macOS
does not work reliably. The mount syscall succeeds, `mount` shows it as
active, but reads and writes silently fall through to the parent mount's
subdirectory. This is a kernel-level limitation in Apple's VirtioFS
implementation (AppleVirtIOFS.kext), not a configuration error.

Linux does not have this problem.

## Observed behavior

Environment: macOS Tahoe 26.x guest on macOS host, Apple Virtualization
framework (VZVirtualMachine), VirtioFS via VZVirtioFileSystemDeviceConfiguration.

Setup:
- `/Users/admin` is VirtioFS device "dvm-home" backed by host `~/.local/state/dvm/home/`
- `/Users/admin/.claude` should be VirtioFS device "home-1" backed by host `~/.claude`

Observations:

1. `mount` shows both mounts as active:
   ```
   virtio-fs on /Users/admin (AppleVirtIOFS, nodev, nosuid)
   virtio-fs on /Users/admin/.claude (AppleVirtIOFS, nodev, nosuid)
   ```

2. Immediately after mounting, the nested mount appears to work — files from
   host `~/.claude` are visible in the guest.

3. After some time, or after a process writes to `/Users/admin/.claude`, the
   mount silently breaks:
   - Writes go to the parent VirtioFS's subdirectory
     (`~/.local/state/dvm/home/.claude/`), not to host `~/.claude`
   - Previously visible host files disappear from the guest
   - `mount` still shows the mount as active

4. A nested mount where the parent has NO content at that subdirectory
   (e.g., `.unison/` is empty on the parent) works initially but is
   subject to the same eventual failure.

5. When the parent's subdirectory already has content from a previous
   session, the nested mount never works — it shows in `mount` but
   serves the parent's content from the start.

6. `umount /Users/admin/.claude` returns "Invalid argument" (EINVAL).

## Root cause: vnode identity instability

### How macOS VFS mounts work

When `mount_virtiofs home-1 /Users/admin/.claude` runs, XNU:
1. Resolves `/Users/admin/.claude` to a vnode object (vnode X)
2. Looks up `.claude` within the parent VirtioFS, which returns vnode X
3. Sets `vnode_X->v_mountedhere = <mount for home-1>`
4. Sets the `VMOUNTEDHERE` flag on vnode X
5. Holds a `vnode_ref` on vnode X to prevent reclamation

Future path lookups detect the mount by checking `v_mountedhere` during
`lookup_traverse_mountpoints()`.

### How Linux FUSE maintains stability

Linux FUSE uses `fuse_iget()` with `iget5_locked()` to maintain an inode
cache keyed by node ID. Repeated lookups of the same directory always return
the identical inode object. If the inode changes, FUSE explicitly invalidates
the dentry and retries, preserving mount bindings.

### How macOS VirtioFS breaks

AppleVirtIOFS is a closed-source kernel extension (not in the open-source XNU
distribution). Based on observed behavior and known bugs, it does NOT
guarantee vnode identity stability. Under certain conditions (cache
invalidation, memory pressure, time-based expiry, writes to the parent
mount's backing directory), VirtioFS returns a **different vnode** (vnode Y)
for the same path.

When this happens:
- `vnode_Y->v_mountedhere` is NULL (no mount was placed on this vnode)
- `VMOUNTEDHERE` is not set on vnode Y
- `lookup_traverse_mountpoints()` sees no mount, falls through to parent
- Parent VirtioFS serves its own subdirectory content
- The mount is still alive on vnode X (ref-counted), so `mount` shows it
- `umount` returns EINVAL because covered vnode X is unreachable

The XNU name cache uses a `mount_generation` counter to invalidate cached
paths when mounts change, but this counter only increments on mount add/remove
— not when the parent filesystem swaps out the underlying vnode.

## Behavior matrix

| Scenario | Result | Explanation |
|---|---|---|
| Mount nested, parent subdir empty | Works initially, breaks later | VirtioFS vnode refresh returns new vnode |
| Mount nested, parent subdir has content | Never works | Parent's existing vnode is strongly cached |
| `mount` output after failure | Still shows mount | Mount struct alive on unreachable vnode X |
| `umount` after failure | EINVAL | Covered vnode unreachable through namespace |
| Writes after failure | Go to parent VirtioFS | Lookup resolves through vnode Y (no mount) |

## Evidence from other projects

### Tart (cirruslabs/tart)

Issue #567 (open, labeled "not possible atm") — VirtioFS volumes flake with
"No such file or directory." Filed as Apple Feedback FB12594177. Tart
maintainer @fkorotkov received feedback from Apple that VirtioFS "was
envisioned for sharing a few files from Desktop and is not ready for heavy
I/O." Confirmed broken through macOS Sequoia 15.2.

- https://github.com/cirruslabs/tart/issues/567

### Lima (lima-vm/lima)

PR #4624 implements macOS guest VirtioFS mounts using symlinks to
`/Volumes/My Shared Files/<tag>` rather than direct `mount_virtiofs`. They
explicitly avoid direct VirtioFS mounts on macOS guests, using the automount
mechanism + symlinks instead.

- https://github.com/lima-vm/lima/pull/4624

### Docker for Mac

Issue #7853 — "Bind mounts with nested dst don't work the first time."
VirtioFS path `/run/host_virtiofs/...` shows the same behavior: nested
destinations fail initially, work on retry. Issue #7687 documents
`renameat2` data loss on VirtioFS bind mounts.

- https://github.com/docker/for-mac/issues/7853
- https://github.com/docker/for-mac/issues/7687

### Apple Container (containerization)

Issues #678 (mount points with >300 subdirs don't share all), #141 (no
inotify propagation on VirtioFS), #1251 (single file mounts fail
intermittently). Apple engineers confirm "this seems solely a strange
interaction with the virtiofs device (macOS changes would be needed)."

- https://github.com/apple/containerization/issues/678
- https://github.com/apple/containerization/issues/141
- https://github.com/apple/containerization/issues/1251

### XNU kernel source

AppleVirtIOFS.kext is NOT in the open-source XNU distribution. The
`bsd/miscfs/` directory contains union, nullfs, bindfs, etc. but no virtiofs.
The vnode identity stability behavior cannot be verified from source — only
inferred from observed behavior and the evidence above.

## Implications for DVM

DVM cannot use nested VirtioFS mounts for home directory overlays. The
`dvm-home` VirtioFS mount at `/Users/admin` makes it impossible to overlay
additional VirtioFS mounts (`.claude`, `.codex`, `.unison`) at subdirectories
of `/Users/admin`.

### Workaround options considered

**Symlinks (Lima's approach):** Mount VirtioFS devices at a non-overlapping
path (e.g., `/var/dvm-mounts/claude`), symlink from `~/.claude`. Trade-off:
`pwd` resolves through symlinks on macOS, so processes in `~/.claude` see
their working directory as `/var/dvm-mounts/claude`. This breaks the
invariant that `pwd` shows the real host path (already noted in
MountConfig.swift line 55). For config directories (`.claude`, `.codex`)
this is likely acceptable — they're not project working directories.

**bindfs/nullfs overlay:** Mount VirtioFS at a neutral path, then use
`mount -t bindfs` or `mount_nullfs` to expose it at the desired guest path.
Avoids symlink pwd resolution. Unclear if bindfs/nullfs available in stock
macOS guest without additional packages.

**VZMultipleDirectoryShare:** Investigated and ruled out — see section below.

**Don't mount home as VirtioFS:** Revert `dvm-home` and increase guest disk
size instead. Gives up the benefits of host-backed home (persistence across
rebuilds, no disk size limit) but avoids the nesting problem entirely.

### Recommendation

**Symlinks.** The pwd concern only applies to project directories (mirror
mounts), which are NOT nested inside `dvm-home` — they mount at host paths
like `/Users/gaborkerekes/projects`. Home mounts (`.claude`, `.codex`,
`.unison`) are config directories where pwd resolution doesn't matter.

## VZMultipleDirectoryShare investigation

Evaluated as a potential alternative to avoid nested mounts.

### How it works

`VZMultipleDirectoryShare` presents multiple named directories under a single
`VZVirtioFileSystemDeviceConfiguration` device, instead of one directory per
device (`VZSingleDirectoryShare`). Created with a dictionary mapping names to
`VZSharedDirectory` objects.

On macOS guests, using the special `macOSGuestAutomountTag`, directories
automount under `/Volumes/My Shared Files/<name>` without manual
`mount_virtiofs` calls.

### Cannot be reconfigured at runtime

The directory set is fixed at VM creation time, same as VZSingleDirectoryShare.
Apple's Virtualization framework does not expose APIs for hot-plugging or
hot-removing directory shares while the VM is running. This is a fundamental
framework limitation, not a missing feature.

Evidence:
- VZVirtualMachineConfiguration is immutable after VM start
- No runtime modification API in the VZ framework
- UTM confirms: new shares require VM restart (discussions/5463)
- libvirt virtiofs documentation shows static configuration only

### Does not solve the nesting problem

Even with VZMultipleDirectoryShare, the directories would still need to be
exposed at paths under `/Users/admin` (the dvm-home mount). Whether they
arrive via automount at `/Volumes/My Shared Files/` or via direct mount,
they still need symlinks or bind mounts to appear at `~/.claude`, `~/.codex`,
etc. The symlink step is the same regardless of the underlying share type.

### Does not help with hot-mounting

A potential future requirement: `dvm switch` adding new mounts (e.g., a new
agent declares `.newagent` as a home mount) without restarting the VM.
VZMultipleDirectoryShare cannot help — the directory set is fixed at VM
creation. Hot-mounting would require a different approach entirely
(pre-allocated spare devices, or a proxy filesystem).

### Conclusion

VZMultipleDirectoryShare adds architectural complexity (single device, shared
namespace, automount behavior) without solving either the nesting problem or
the hot-mounting question. The simpler approach — individual VirtioFS devices
mounted at non-nested paths + symlinks — is equivalent in capability and
proven in production (Lima).

Sources:
- Apple Developer Documentation: VZDirectorySharingDeviceConfiguration
- WWDC 2022: Create macOS or Linux virtual machines
- Code-Hex vz library wiki: Shared Directories
  (https://github.com/Code-Hex/vz/wiki/Shared-Directories)
- UTM discussions: Multiple shared directories
  (https://github.com/utmapp/UTM/discussions/5463)
