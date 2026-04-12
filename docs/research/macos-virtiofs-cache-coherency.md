# macOS VirtioFS cache coherency bugs

Date: 2026-04-01

Two distinct bugs have been observed in Apple's VirtioFS implementation
(AppleVirtIOFS.kext). Both stem from the same root: the server does not push
cache invalidation notifications to the guest.

**Bug 1 — Stale dentry after host atomic rename** (see sections below through
"Implications for DVM"). When a file is atomically replaced on the host, the
guest's dentry cache retains the old deleted inode. Symptom: `ls` shows link
count 0, `open()` returns ENOENT. Fixed by guest-side remount (`dvctl remount`).

**Bug 2 — Server-side readdir cache for directories empty at VM startup** (see
"Bug 2" section at the end). When a VirtioFS-shared directory is empty at VM
startup, the server caches that empty state. Files added to the host directory
later are invisible in the guest even after remount. `stat` returns correct
mtime (server tracks inode metadata) but `readdir` returns no entries and file
creation returns ENOENT. Fixed only by VM restart.

---

## Bug 1: stale dentry after host atomic rename

### Summary

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

#### Operational cost: NFS requires host privilege

If DVM manages NFS dynamically at runtime, it needs root privileges on the host.
The privileged operations are not incidental; they are part of how macOS NFS is
administered:

- updating `/etc/exports`
- validating exports with `nfsd`
- starting or reloading `nfsd`

That means a design where `dvm start` automatically configures host exports for
the current VM run will require elevation (for example `sudo` / Touch ID) unless
privilege is moved somewhere else.

There are three realistic operational models:

1. **Dynamic host-managed NFS exports**
   DVM edits `/etc/exports` and updates `nfsd` as part of startup/shutdown.
   This is the most automatic model, but it requires host root privileges at
   runtime.

2. **One-time manual root setup**
   The user preconfigures `/etc/exports` and ensures `nfsd` is already enabled.
   DVM then only performs guest-side mounts. This can reduce or eliminate
   repeated runtime prompts, but it gives up dynamic per-run export management
   and makes setup more manual.

3. **Privileged helper / daemon**
   A root-owned helper manages exports on behalf of unprivileged `dvm`.
   This can eliminate repeated interactive prompts during normal runs, but it
   does not eliminate privilege from the system overall; it centralizes it into
   a dedicated helper.

The important distinction is:

- **reducing prompt churn** is feasible
- **eliminating privilege entirely** is not compatible with dynamic host-managed NFS

So if "no repeated Touch ID prompts" is the goal, that is solvable with either
manual preconfiguration or a privileged helper. If "no host privilege anywhere"
is the goal, NFS is the wrong transport.

#### Other alternatives considered

**Reverse SSHFS / SFTP mounts**

Tools like Lima support `reverse-sshfs` as an alternative mount type. This
avoids Apple's VirtioFS bugs because the guest talks to a userspace filesystem
server over SSH rather than Apple's kernel VirtioFS path. The downside is
performance and operational complexity: SSHFS is generally slower than NFS for
metadata-heavy workloads, introduces another long-lived transport/process to
supervise, and broadens the blast radius if the guest compromises the mount
session. Worth considering as a fallback or prototype, but not the preferred
long-term design.

**SMB / macOS network file sharing**

The host can export directories via macOS file sharing and the guest can mount
them over SMB. This is a valid alternative to VirtioFS and is explicitly
recommended by some macOS VM tooling as the generic "network share" path.
However, SMB is a worse fit for a Unix-heavy development environment: metadata
semantics, permissions, symlink behavior, and shell/tool compatibility are
generally rougher than NFS. If NFS proves operationally difficult, SMB is worth
testing, but it is not the first choice.

**Workspace sync instead of a live shared filesystem**

Rather than sharing the host directory live, the guest could keep its own local
copy of the workspace and synchronize changes in and out with a replication tool
(Mutagen/Unison/Syncthing-style). This avoids live coherency bugs entirely and
can preserve good guest-side performance because the guest mostly works against
its own local disk. The trade-off is semantic complexity: the system stops being
"a shared directory" and becomes "a replicated workspace" with conflict,
latency, and tooling implications. This is the most serious alternative if NFS
is too slow or too operationally awkward, but it is a larger workflow change.

**9p / QEMU-style filesystems**

9p is used by some QEMU-based systems, but it is not a natural fit for DVM's
current Virtualization.framework backend and comes with its own cache/performance
trade-offs. Pursuing 9p would imply a much larger architectural shift than
switching from VirtioFS to NFS, so it is not a practical next step.

**Custom filesystem / OrbStack-style design**

The "best" user experience would come from a custom host↔guest filesystem that
pushes invalidation events correctly (the way OrbStack appears to do). In
practice this is not a realistic option for DVM today: it would require a
substantial custom implementation, likely deep integration with host filesystem
events, and possibly guest-side kernel support or Apple fixes. This is useful
as a conceptual benchmark, not as a near-term plan.

#### Recommendation

If DVM moves away from VirtioFS for mutable project directories, the strongest
next experiment is:

1. Use NFS for project mirror mounts only.
2. Keep VirtioFS for mounts where coherency is less critical or immutability is
   the point (for example `/nix/store`).
3. If NFS is too slow or too operationally awkward, revisit a sync-based
   workspace model before exploring more exotic filesystem protocols.

#### Early benchmark signal: NFS fixes coherence, but VirtioFS is much faster for Bun installs

A small Bun benchmark was run in four configurations:

- host local APFS
- DVM with the repo on an NFS mirror
- DVM with the repo on a VirtioFS mirror
- DVM with the repo copied to guest-local storage

Measured wall-clock times:

- **Host APFS**
  - cold: `0.55s`
  - warm: `0.04s`
- **DVM on NFS**
  - cold: `14.34s`
  - warm: `12.78s`
- **DVM on VirtioFS**
  - cold: `5.44s`
  - warm: `3.68s`
- **DVM guest-local**
  - cold: `6.84s`
  - warm: `4.47s`

Interpretation:

- Moving the repo off NFS cuts the DVM install time substantially, so NFS is a
  major part of the slowdown for this workload.
- Switching from NFS to VirtioFS improves the shared-mount case even more:
  - cold: `14.34s -> 5.44s`
  - warm: `12.78s -> 3.68s`
- VirtioFS is still much slower than host, so the VM/shared-filesystem overhead
  remains real even in the faster shared-mount case.

Practical implication:

- **NFS** still looks like the safer transport when host→guest coherency is the
  hard requirement.
- **VirtioFS** is much better for package-manager-heavy workloads like
  `bun install`, if the known host→guest coherency bugs are acceptable for the
  repo/workflow.

So the tradeoff is sharper now:

- choose NFS for coherence
- choose VirtioFS for install/build speed
- or keep hot dependency/build directories guest-local when the repo needs both

Detailed benchmark notes live in
[/Users/gaborkerekes/projects/dvm-bun-install-bench/RESULTS.md](/Users/gaborkerekes/projects/dvm-bun-install-bench/RESULTS.md).

---

## Bug 2: server-side readdir cache for directories empty at VM startup

### Summary

When a VirtioFS-shared directory is **empty at VM startup**, the Apple VirtioFS
server caches that empty state. Files subsequently written to the host directory
are invisible in the guest: `readdir` returns no entries and file creation
returns ENOENT. Guest-side remount does not help because the VZ hypervisor
process (and its VirtioFS server) keeps running — only a VM restart reinitialises
the server.

### Observed behavior in DVM

> Note: this describes the historical default before `nix-darvm-65k0`.
> DVM no longer mounts `~/.cache/nix` from the host by default; the guest now
> keeps its Nix cache on local APFS specifically to avoid this failure mode.

DVM mounts `~/.cache/nix` as a VirtioFS share (`nix-cache` tag). The guest
symlinks `~/.cache/nix` → `/var/dvm-mounts/nix-cache`.

When the VM starts before the host's `~/.cache/nix` has been populated by nix:

```
# Guest — ls returns nothing
[dvm] $ ls /var/dvm-mounts/nix-cache
[dvm] $

# Host — has files (populated after VM started)
$ ls ~/.cache/nix
eval-cache-v6    fetcher-cache-v4.sqlite

# Guest — nix fails to open OR create the database
[dvm] $ nix develop
error: cannot open SQLite database '"~/.cache/nix/fetcher-cache-v4.sqlite"':
       unable to open database file
```

The `stat` of the mount root in the guest reveals the inconsistency:

```
Inode: 1  Links: 2  Size: 64
Modify: 2026-04-01 19:33:14 +0000   ← matches host mtime exactly
```

The mtime is correct (the server tracks inode metadata via fresh `stat()` calls)
but `readdir` returns zero entries and `create` returns ENOENT. The server is
serving two different code paths inconsistently: `getattr` reads live from the
host, `readdir`/`create` use a stale cached state from VM startup.

### Root cause

The Apple VirtioFS server appears to open the host directory at VM creation time
and cache the resulting directory handle or its initial (empty) listing. It does
not reopen or rewind the directory when the guest issues a fresh FUSE `OPENDIR`.
Subsequent `READDIR` calls return the stale empty result; `CREATE` calls fail
because the server's internal directory state is inconsistent.

This is distinct from Bug 1:
- Bug 1 is a **guest-side** dentry cache issue (server is correct, guest is
  stale) → guest remount clears it.
- Bug 2 is a **server-side** readdir cache issue (server is stale) → only VM
  restart clears it.

### Fix: VM restart

Restarting the VM reinitialises the VirtioFS server. If the host directory has
content at that point, the server opens it correctly and serves the full listing.

```sh
dvm stop && dvm start
```

### When it triggers

Only when the VirtioFS-shared directory is **empty at VM startup**. If the
directory already contains files when `dvm start` runs, the server initialises
with correct state and Bug 2 does not manifest (though Bug 1 may still apply
if files are atomically replaced later).

For DVM, this means the `nix-cache` mount is vulnerable on first use of a new
host machine or after clearing `~/.cache/nix`. Subsequent VM restarts are safe
once the cache has been populated.
