# macOS VirtioFS cache coherency: host-side atomic rename

Date: 2026-04-01

## Summary

When a file in a VirtioFS-shared directory is atomically replaced on the host
(write-to-temp + rename — the standard safe-write pattern used by editors, git,
compilers, package managers), the guest's VFS dentry and inode caches are not
invalidated. The guest retains a reference to the old, now-unlinked inode. The
file appears in `ls` with link count 0; `open()` / `cat` return ENOENT.

This is a confirmed, unresolved kernel bug in Apple's VirtioFS implementation
(AppleVirtIOFS.kext). It has been independently reported by Tart, Docker,
Podman, vfkit, and Apple's own container project. **There is no mount-time
option to disable caching.** The only reliable recovery is unmounting and
remounting the affected VirtioFS device.

## Observed behavior in DVM

Environment: macOS guest on macOS host, Virtualization.framework,
VZVirtioFileSystemDeviceConfiguration, `mount_virtiofs`.

1. File is created in guest → visible on host ✓
2. Host editor (nvim) saves file via atomic rename → visible on host ✓
3. Guest tries to read the file:
   ```
   $ ls -lah | grep gitignore && cat .gitignore
   -rw-r--r--  0 admin  staff   362 Apr  1 18:28 .gitignore
   cat: .gitignore: No such file or directory
   ```

The link count `0` in the `ls` output is diagnostic: the guest is serving
attributes from the old deleted inode (unlinked on host by the rename). The
directory entry still points to it in the guest's dentry cache, but the inode
is gone on the host. `open()` triggers a fresh VirtioFS `LOOKUP` which either
returns ENOENT or maps to a different inode that the kernel rejects, producing
ENOENT at the syscall level.

Remounting the VirtioFS device restores a correct view:
```sh
sudo umount /Users/gaborkerekes/projects
sudo mount_virtiofs mirror-3 /Users/gaborkerekes/projects
# file now readable
```

## Root cause: no host→guest cache invalidation

### How the protocol gap works

VirtioFS is a FUSE-derived protocol. The FUSE spec includes notification
messages for host→guest cache invalidation:

- `FUSE_NOTIFY_INVAL_ENTRY` — invalidate a named directory entry
- `FUSE_NOTIFY_INVAL_INODE` — invalidate a cached inode

On Linux, `virtiofsd` watches the host filesystem (via inotify) and sends these
notifications when files change. The guest kernel evicts the stale dentry/inode
and re-fetches from the server on next access.

Apple's VirtioFS is a closed-source kernel extension (AppleVirtIOFS.kext, not
in the open-source XNU distribution). It does **not** implement
`FUSE_NOTIFY_INVAL_ENTRY` or `FUSE_NOTIFY_INVAL_INODE`. When the host renames
a file, no notification reaches the guest. The guest retains the old dentry
pointing to the now-unlinked inode indefinitely — until the VirtioFS device is
remounted or the guest reboots.

### No mount options

`mount_virtiofs` on macOS accepts only three flags: `-r` (read-only), `-u uid`,
`-g gid`. There is no `-o noattrcache`, `-o nocache`, `-o entry_timeout=0`, or
equivalent. The options available in macFUSE (`nolocalcaches`, `novncache`,
`noubc`) do not apply here; AppleVirtIOFS is a first-party kernel filesystem,
not FUSE-based from the guest's perspective.

Sources:
- `mount_virtiofs` man page: https://keith.github.io/xcode-man-pages/mount_virtiofs.8.html
- Apple Developer docs: https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration

## Evidence from other projects

### Cirrus Labs / Tart (FB12594177)

Issue #567 — "Mounted volumes flake with No such file or directory" (open,
labeled "not possible atm"). The Tart maintainer filed Apple Feedback
**FB12594177**. Apple's reply: VirtioFS "was envisioned for sharing a few files
from Desktop and is not ready for heavy I/O." Confirmed broken through macOS
Sequoia 15.2.

**Tart subsequently reverted automatic host directory mounting via VirtioFS
entirely**, citing the unreliability.

- https://github.com/cirruslabs/tart/issues/567

### Apple Container (containerization)

Issue #141 — "No inotify notifications when host changes file in virtiofs."
Apple engineers confirm the missing invalidation path: "this seems solely a
strange interaction with the virtiofs device (macOS changes would be needed)."
This is Apple's own container project, filed against their own VirtioFS
implementation. The issue is labeled as a priority "next" item with no
timeline.

- https://github.com/apple/containerization/issues/141

### crc-org/vfkit

Issue #126 — "No inotify/FSEvents notifications in Linux VM when host changes
file in virtiofs mount." The same missing `FUSE_NOTIFY_INVAL_ENTRY` gap,
documented from the Linux-guest side of the same Apple VirtioFS server.

- https://github.com/crc-org/vfkit/issues/126

### Docker for Mac

Issue #7246 — "Missing DELETE inotify event with VirtioFS" (open as of April
2024). Renamed/deleted files on the host are not visible to Linux guest
processes watching via inotify.

Issue #7501 — "VirtioFS file size not matching host." `stat()` bypass of
the dentry cache is inconsistent: `ls` can trigger a refresh in some cases but
not for the rename/unlink variant.

- https://github.com/docker/for-mac/issues/7246
- https://github.com/docker/for-mac/issues/7501

### containers/podman

Issue #23061 / Discussion #23886 — "macOS VM virtiofs concurrency issue."
Documents the stale inode after atomic rename, specifically the link-count-0
symptom. Closed as Apple's problem; no mitigation applied by Podman.

Issue #24725 — Spurious `EACCES` on `mkdirat` via Virtualization.framework
VirtioFS (filed December 2024, Sequoia 15.1.1), indicating the class of bugs
is ongoing in Sequoia.

- https://github.com/containers/podman/issues/23061
- https://github.com/containers/podman/discussions/23886
- https://github.com/containers/podman/issues/24725

## macOS 15 Sequoia status

Anecdotal reports (podman discussion #23886, rust-lang/docker-rust#161) suggest
the **synthetic-inode / hardlink variant** of the bug may be improved on
Sequoia. However:

- The general case of host-side atomic rename producing stale guest dentries
  remains unresolved or unreliably fixed (Docker #7246 remains open as of
  April 2024, filed against Sequoia).
- The `mkdirat EACCES` regression (podman #24725) was filed against Sequoia
  15.1.1 in December 2024, showing the class of VirtioFS bugs is ongoing.
- There is no Apple release note or developer documentation confirming any
  VirtioFS cache coherency fix.

## Linux kernel workaround (does not apply to macOS guest)

Docker Desktop 4.28 (February 2024) shipped a patch to the Linux kernel in
their guest that sets `entry_valid = 0` for FUSE lookup results where the
inode has `i_nlink > 1` and is not a directory (`fs/fuse/dir.c`). This
prevents caching dentries for files that can change inode identity.

This workaround only applies to **Linux guests** using Linux's FUSE/VirtioFS
client. A macOS guest uses AppleVirtIOFS.kext — a different kernel filesystem
with no analogous patch point accessible from userspace or the Virtualization
framework API.

## No userspace cache drop mechanism

- `kern.namecache_disabled` sysctl exists in XNU but is not writable from
  userspace (returns `Operation not permitted`).
- `sudo purge` flushes the disk buffer cache globally but does not target a
  specific mount's dentry or vnode cache. Confirmed ineffective for this issue.
- The XNU kernel function `cache_purge()` (which does per-vnode name cache
  invalidation) is not callable from userspace.
- There is no per-mount equivalent of Linux's `/proc/sys/vm/drop_caches`.

## Implications for DVM

DVM mounts project directories as VirtioFS mirror shares (`mirror-0`,
`mirror-1`, …). Any file in these directories that is atomically replaced on
the host — by the developer's editor, `git`, `jj`, `npm install`, or any other
tool using the standard safe-write pattern — becomes invisible to the guest
until the share is remounted.

This affects the "human edits file on host, agent reads it in guest" direction.
The reverse direction (agent writes in guest, human reads on host) is
unaffected: the host accesses the underlying filesystem directly, not through
VirtioFS.

### Current workaround: `dvctl remount`

`dvctl remount` (added in guest-plumbing.nix) unmounts and remounts all
`mirror-*` VirtioFS shares in the guest, clearing the stale dentry cache:

```sh
# In the DVM guest shell — cd out of project directories first
dvctl remount
```

The command parses `mount | grep '^mirror-'` to discover active mirror shares
and remounts each one. If the current directory is inside a mirror share, the
`umount` will fail with "device busy"; `cd /tmp` first.

### Long-term alternative: NFS

macOS has a built-in NFS server (`nfsd`). NFSv4 with `actimeo=1` (or `actimeo=0`
for immediate coherency) forces the client to revalidate file attributes on every
`open()` or within the TTL window, so atomic renames on the host are visible to
the guest within at most `actimeo` seconds. The guest already has a local IP via
the VM's network interface.

#### Performance trade-off

**Data throughput** (large sequential reads/writes) is roughly comparable to
VirtioFS. Both cross a VM boundary; neither achieves local filesystem speed.

**Metadata latency** is where NFS costs more. With `actimeo=0`, every `stat()`,
`open()`, and directory lookup is an RPC round-trip to the server. Even on
loopback that is ~100µs vs ~1µs for a cached VirtioFS lookup. Stat-heavy
workloads — `git status` on a large repo, `npm install`, `nix build` — do
thousands of stats and will be measurably slower.

With `actimeo=1` the NFS client caches attributes for one second, so metadata
ops are cheap between revalidations. For an AI coding agent doing file edits,
one-second staleness on host-side writes is acceptable.

#### The right comparison

The relevant comparison is not NFS vs pristine VirtioFS — it is NFS vs
VirtioFS-with-catastrophic-cache-misses. A stale VirtioFS dentry is not slow;
it returns ENOENT. NFS with `actimeo=1` is *consistently correct* and
*consistently fast enough*, whereas VirtioFS is fast when the cache is warm and
completely broken after any host-side atomic rename.

#### Why OrbStack is faster

OrbStack's custom filesystem uses FSEvents on the host to push invalidation
notifications directly to the guest, combined with shared memory for data
transfer. This is VirtioFS done correctly — no round-trips for cached data,
immediate coherency on host writes. Replicating this would require either a
notarized macOS guest kernel extension or Apple fixing AppleVirtIOFS.kext.
Neither is currently feasible.

#### Status

NFS is the most viable architectural fix for correct long-term coherency, but
introduces setup and lifecycle complexity (exports configuration, nfsd
management, dynamic guest IP across reboots). Not yet implemented.
