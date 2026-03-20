---
# nix-darvm-g5dm
title: 'Swift: project-local secrets (HMAC placeholders, exec-time resolution, manifest discovery)'
status: completed
type: task
priority: normal
created_at: 2026-03-20T18:57:17Z
updated_at: 2026-03-20T19:31:09Z
parent: nix-darvm-27hf
blocked_by:
    - nix-darvm-6e9t
---

Full Swift-side implementation of project-local secrets. Merges the original
g5dm scope (HMAC + exec-time resolution) with qkg2 (manifest discovery + CLI
wiring) since both touch the same code paths and can't be verified independently.

Design: docs/project-local-secrets.md
Codex review findings incorporated below.

## Implementation order

### 1. Always-on sidecar + CA (prerequisite)

Current code only launches the sidecar when startup discovers manifests, and
only installs the CA when secrets are resolved. After this change, startup
discovery goes away — so the sidecar must always start and the CA must always
be installed, even with zero credentials.

- [x] `Main.swift` (`Start.run`): always launch `NetstackSupervisor` and install CA cert in guest, regardless of whether any credentials.toml exists
- [x] `Main.swift` (`Start.run`): stop sending secrets in `load_config` — proxy starts empty
- [x] Remove all credential resolution from `Start.run` (manifest scanning, secret resolution, initial load)

### 2. Cross-process credential loading via ControlSocket

`dvm exec` is a separate process. It cannot reach the sidecar directly — it
must ask `dvm start` to forward credentials via the existing ControlSocket
(`/tmp/dvm-control.sock`).

- [x] `ControlSocket.swift`: add `loadCredentials` command to `Command` enum
- [x] `ControlSocket.swift`: `handleRequest` for `loadCredentials` — receives project name + secret rules, calls `NetstackSupervisor.reloadSecrets()`, returns ok/error
- [x] `ControlSocket.swift`: give it a reference to the supervisor (or a closure, like `guestHealthHandler`)
- [x] `ControlSocket.swift` client side: add `static func sendLoadCredentials(...)` for use by `Exec`/`SSH`

### 3. SecretConfig.swift (rewrite)

- [x] New TOML parser for v2 format: `version = 1`, `project` field, `[secrets.<ENV_VAR>]` tables with `hosts` arrays
- [x] Delete `InjectMode` enum, `SecretProvider` enum, `SecretResolver` class
- [x] Delete `generatePlaceholder()` (random hex)
- [x] New `HostKey` type: load-or-create 32 random bytes at `~/.local/state/dvm/placeholder.key`
- [x] New `derivePlaceholder(project:secret:hostKey:)` → `SANDBOX_CRED_{project}_{secret}_{hmac_suffix}` where hmac_suffix = first 16 hex of HMAC-SHA256(hostKey, "{project}\0{secret}")
- [x] Normalization rules (nail down exact strings for wire/HMAC/display):
  - **Wire** (`project_name` sent to sidecar): normalized project name
  - **HMAC input**: `"{normalized_project}\0{original_env_var_name}"`
  - **Display** (in placeholder): slugified project + slugified secret
  - Project normalization: lowercase, strip leading/trailing whitespace
  - Secret slug (display only): lowercase, non-alphanumeric → `-`, collapse runs
  - Host normalization: lowercase, strip trailing dots (match Go sidecar's `normalizeHost`)

### 4. NetstackSupervisor.swift (wire protocol update)

- [x] Delete `encodeSecret` inject serialization (bearer/basic/header)
- [x] `ResolvedSecret`: remove `inject` field
- [x] `reloadSecrets`: rename `projectRoot` → `projectName` in JSON wire format
- [x] Delete `unloadProject` method
- [x] `buildLoadMessage`: stop including secrets in `load_config` config

### 5. Manifest discovery + CLI wiring (merged from qkg2)

- [x] `Exec` command: add `--credentials <path>` option
- [x] `SSH` command: same `--credentials <path>` option
- [x] Discovery priority: `--credentials` flag > `DVM_CREDENTIALS` env var > `.dvm/credentials.toml` in cwd
- [x] No directory walking — if none found, session runs without credentials
- [x] Explicit source (`--credentials` or `DVM_CREDENTIALS`) pointing to missing/unreadable file = loud error (not silent fallthrough)
- [x] Empty `DVM_CREDENTIALS` = error, not "unset"
- [x] Relative paths resolve against host cwd
- [x] `Config.swift`: delete old `credentialManifestPaths` (mirror-dir based scanning) — this is a behavior change, not just a refactor

### 6. Exec/SSH credential flow

The full flow when `dvm exec` runs:

1. Discover manifest (step 5 priority chain), or skip if none found
2. Parse manifest → list of `(env_var_name, hosts[])` pairs
3. Read each env var from host environment — fail loudly if missing
4. Load host key (step 3 `HostKey`)
5. Derive placeholder for each secret (step 3 `derivePlaceholder`)
6. Send `loadCredentials` to ControlSocket → `dvm start` forwards to sidecar
7. Inject `ENV_VAR_NAME=<placeholder>` into guest session env

- [x] Wire up the full flow in `Exec.run()` and `SSH.run()`
- [x] Malformed manifest = loud error with path and parse error

## Verification

- [x] Build: `swift build` (host/)
- [x] `dvm start` with no manifest: sidecar starts, CA installed, no credential load
- [x] `dvm exec` with no manifest: runs normally, no credential load, no error
- [x] `ANTHROPIC_API_KEY=sk-test dvm exec -- env | grep SANDBOX_CRED`: placeholder injected
- [x] HTTPS request with placeholder in Authorization header: replaced by proxy
- [x] HTTP request with placeholder: NOT replaced (passes through as-is)
- [x] `dvm exec --credentials ./other/credentials.toml -- env`: discovers from flag
- [x] `DVM_CREDENTIALS=./path dvm exec -- env`: discovers from env var
- [x] `--credentials` with missing file: loud error
- [x] Malformed manifest: loud error with path
- [x] Missing env var declared in manifest: loud error naming the var
- [x] Same project exec twice: second overwrites first (no collision)
- [x] `load` JSON uses `project_name`, omits `inject`


## Post-implementation

- [x] Codex review (resume session from 6e9t review)
- [x] Address critical findings
- [x] Report remaining findings to user

## Automated test coverage (58 Swift + 13 Go tests)

- SecretConfigTests.swift: placeholder derivation, slugify, normalize, manifest load/resolve, HostKey filesystem
- DiscoveryTests.swift: manifest discovery chain (flag, env var, CWD, priority, errors)
- control_test.go: same-project overwrite, collision detection, missing project
- http_test.go + https_test.go: placeholder replacement (HTTPS), passthrough (HTTP)
