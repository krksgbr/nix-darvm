# JJ inside DVM on macOS VirtioFS

## Summary

`jj` is currently unreliable when the repo lives on a host-mounted DVM path such as:

- `/Users/gaborkerekes/projects/...`
- `/Users/gaborkerekes/playground/...`

Inside the guest, those paths are mounted as `AppleVirtIOFS`. When `jj` needs to snapshot a dirty working copy, it writes metadata under `.jj/` and tries to durably flush a temp file before renaming it into place. On Apple platforms that flush path goes through `F_FULLFSYNC`, which `AppleVirtIOFS` does not support. The result is:

```text
Internal error: Failed to check out a commit
Caused by:
1: Failed to create new working-copy commit
2: Failed to write non-git metadata
3: Failed to save table segment '...'
4: Inappropriate ioctl for device (os error 25)
```

This is not specific to `sibyl-memory-mvp`; it reproduces in a tiny dummy repo too.

## What we verified

### Host-mounted repo inside DVM: dirty `jj st` fails

Creating a fresh untracked file in either of these repos causes `jj st` to fail inside DVM:

- `/Users/gaborkerekes/projects/sibyl-memory-mvp`
- `/Users/gaborkerekes/playground/dvm-jj`

Typical failure:

```text
Internal error: Unexpected error from backend
Caused by:
1: Failed to write non-git metadata
2: Failed to save table segment '...'
3: Inappropriate ioctl for device (os error 25)
```

### `--ignore-working-copy` still works

This succeeds because it skips the snapshot/write path:

```sh
jj st --ignore-working-copy
```

Useful for read-only inspection, but not as a normal workflow.

### Guest-local repo works

A repo living on the guest's own disk works fine. We verified this both with:

- a fresh repo created under `/tmp`
- a guest-local copy of `sibyl-memory-mvp` under `/Users/admin/work`

## Root cause

The failing JJ path is:

1. dirty working copy triggers snapshot
2. JJ writes non-git metadata under `.jj/`
3. JJ writes a temp file for the metadata segment
4. JJ calls `sync_data()` before persisting it
5. on Apple, Rust implements that via `fcntl(F_FULLFSYNC)`
6. `AppleVirtIOFS` returns `ENOTTY` / `Inappropriate ioctl for device`
7. JJ treats that as fatal

The relevant JJ/Rust code paths we inspected were:

- `jj/lib/src/stacked_table.rs`
- `jj/lib/src/file_util.rs`
- Rust stdlib `std/src/sys/fs/unix.rs` on Apple

## Temporary workaround

Use a **guest-local working copy** for JJ.

### Why this is the least annoying workaround for now

- keeps `jj` functional inside DVM
- avoids patching JJ or DVM
- preserves the repo's existing `.git` and `.jj` data
- avoids the failing `AppleVirtIOFS` metadata write path

### Important caveats

- Do **not** use `cp -R` for this repo. It runs into symlink/xattr problems in `node_modules`, `.direnv`, and other generated trees.
- The copied repo inherits JJ's per-repo secure-config pointers from the host. Those pointers must be removed once in the guest-local copy so JJ can regenerate local secure config state.
- Treat the guest-local copy as your active workspace for the session. Do not blindly sync the whole tree back over the host copy after making changes.

## Bootstrap commands

Run these from the host while DVM is running.

If you are invoking `dvm` from a restricted host sandbox that cannot access `~/.config/dvm`, add `--no-credentials` to `dvm exec` for these commands.

```sh
dvm exec -- sh -lc '
  set -e
  rm -rf /Users/admin/work/sibyl-memory-mvp
  mkdir -p /Users/admin/work/sibyl-memory-mvp
  rsync -a --delete \
    --exclude node_modules \
    --exclude .direnv \
    --exclude result \
    --exclude .fastembed_cache \
    --exclude .claude/worktrees \
    /Users/gaborkerekes/projects/sibyl-memory-mvp/ \
    /Users/admin/work/sibyl-memory-mvp/

  cd /Users/admin/work/sibyl-memory-mvp

  # The copied repo points at host-side JJ secure-config locations.
  # Remove those pointers so JJ regenerates guest-local secure config state.
  rm -f .jj/repo/config-id .jj/repo/config.toml
'
```

Then work in the guest-local copy:

```sh
dvm exec -- sh -lc '
  cd /Users/admin/work/sibyl-memory-mvp
  jj st
'
```

Or open a shell there:

```sh
dvm exec -- sh -lc 'cd /Users/admin/work/sibyl-memory-mvp && exec $SHELL -l'
```

## Refreshing the guest-local copy from the host copy

Only do this when you are sure you do **not** have guest-local changes you want to keep.

```sh
dvm exec -- sh -lc '
  set -e
  rsync -a --delete \
    --exclude node_modules \
    --exclude .direnv \
    --exclude result \
    --exclude .fastembed_cache \
    --exclude .claude/worktrees \
    /Users/gaborkerekes/projects/sibyl-memory-mvp/ \
    /Users/admin/work/sibyl-memory-mvp/
  cd /Users/admin/work/sibyl-memory-mvp
  rm -f .jj/repo/config-id .jj/repo/config.toml
'
```

If you already made changes in the guest-local copy, inspect and export them intentionally first.

## Moving changes back to the host copy

Safest options:

1. commit in the guest-local repo and push/export from there
2. copy back only the specific files you changed
3. generate a patch from the guest-local repo and apply it on the host copy

Avoid whole-tree reverse sync unless you are certain it is what you want.

## Status

This is a workaround, not a fix.

A proper fix likely needs to happen in JJ (or much lower in the stack) by handling Apple filesystems that do not support the current `sync_data()` / `F_FULLFSYNC` durability path.
