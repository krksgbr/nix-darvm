# Credential Test Harness

The project now exposes VM-backed QA cases through a tiny dispatcher:

- `just test list|show|run ...`
- `just probe list|show|run ...`

Use them with this intent:

- `test`: pass/fail assertions — these are the cases that should pass once the
  behavior is correct
- `probe`: exploratory repro/stress runs — these are for exercising a path,
  reproducing a bug, or collecting artifacts under load

The credential harness specifically is driven through the `test` side:

- `just test list`
- `just test show <id>`
- `just test run <id> [args]`

Current credential cases:

- `credentials.fast`: host-only Swift/Go regression checks
- `credentials.e2e`: full VM-backed credential e2e harness

Example:

```bash
just test run credentials.fast
just test run credentials.e2e --verbose --debug
```

`credentials.e2e` invokes the same full VM smoke path as before, via the
`scripts/tests/credentials.e2e.sh` case entrypoint.

Extra observability flags:


- `--verbose` streams the live `dvm-core start` log during boot
- `--debug` preserves temp artifacts and prints extra assertion/probe context

The e2e harness is self-contained:

- backs up and restores `~/.config/dvm/credentials.toml`
- creates temporary local and global credential fixtures
- boots the existing `darvm-*` VM with the local `dvm-core` and `dvm-netstack`
- refreshes the guest image scripts from the checked-out repo only if the
  installed copies are stale
- reboots only when script refresh or legacy guest cleanup made it necessary
- tears the VM down and removes temp fixtures via shell trap

The e2e suite asserts these invariants:

- `global_env_not_copied_to_etc`
- `global_env_present_in_state_mount`
- `global_env_contains_placeholder_only`
- `global_env_sources_into_shell`
- `local_exec_injects_placeholders`
- `global_https_substitution_works`
- `local_https_substitution_works`

The shell-sourcing and global HTTPS checks run through mounted guest probe
scripts rather than nested inline `sh -lc '...'` strings. That keeps the
assertions aligned with the real product path and avoids host-side quoting
artifacts.

## Temporary guest services in harnesses

When an e2e or repro harness needs a guest-local service that must outlive a
single `dvm exec` call, **do not** start it with shell backgrounding such as:

```sh
dvm exec -- sh -c 'nohup nc -lk 127.0.0.1 4321 >/tmp/x 2>&1 &'
```

That pattern is brittle here because `dvm exec` is a foreground RPC path, while
`nohup ... &` relies on shell detachment semantics that vary with TTY,
launchd, and user/root context. A printed PID does not prove the service is
still alive, listening, or discoverable by the real product path.

Use a temporary `launchd` job instead:

1. generate a temporary plist for the guest helper
2. install it under `/Library/LaunchDaemons/<label>.plist`
3. start it with `sudo launchctl bootstrap system ...` and
   `sudo launchctl kickstart -k system/<label>`
4. write stdout/stderr into `/var/run/dvm-state/...` so the host can capture
   artifacts
5. verify readiness with the **same command and privilege level** the product
   uses (for example `sudo lsof ...` if the guest agent runs the listener scan
   as root)
6. stop it with `sudo launchctl bootout system/<label>` and remove the plist

Rule of thumb: use `dvm exec` for foreground commands, and use `launchd` for
long-lived guest helpers.

Output is flat and explicit:

```text
PASS global_env_not_copied_to_etc
PASS global_env_present_in_state_mount
...
RESULT: PASS (7/7)
```

Failures name the broken invariant directly and report the captured start log
path when boot failed.

## Prerequisites

The e2e suite expects:

- an existing `darvm-*` VM, or `just init` run beforehand
- host tools: `tart`, `curl`, `python3`
- network reachability to `https://httpbin.org/anything`

If any prerequisite is missing, the harness fails loudly instead of trying to
guess around it.
