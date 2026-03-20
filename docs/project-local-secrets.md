# Project-Local Secrets

Mechanism for scoping credentials to individual projects so that multiple
projects can use the proxy simultaneously without cross-project leakage.

## Status quo

- `.dvm/credentials.toml` already lives per-project (no central config)
- `SecretResolver.resolve()` generates random placeholders (`SANDBOX_SECRET_<32 hex>`)
- Placeholders are ephemeral — regenerated on every load, not stable across restarts
- The control socket supports per-project `load`/`unload` keyed by project path
- `HostOverlapChecker` rejects cross-project host conflicts at load time
- Env var injection into `dvm exec`/`dvm shell` is not implemented yet
- Proxy currently uses `inject` mode (bearer/basic/header) to decide how to
  attach credentials to outgoing requests
- Credential resolution currently happens at `dvm start` time in `Main.swift`

## Design

### credentials.toml format

```toml
version = 1
project = "nix-darvm"

[secrets.ANTHROPIC_API_KEY]
hosts = ["api.anthropic.com"]

[secrets.GITHUB_TOKEN]
hosts = ["api.github.com", "uploads.github.com"]
```

- **`project`** (required): human-readable project name. Serves as the
  namespace in placeholder tokens. Must be unique across loaded projects.
  Compared after normalization (lowercase, strip whitespace).
- **`secrets.<ENV_VAR>`**: the TOML key is the env var name read from the
  host environment and injected as a placeholder into guest sessions. This
  is also the secret's identity for placeholder derivation.
- **`hosts`**: which upstream hosts this secret applies to. Normalized the
  same way as the proxy's host matching: lowercase, trailing dots stripped.

No `provider` field. Secret values come from the host environment at
`dvm exec`/`dvm shell` time. The user is responsible for having them set,
using whatever secret manager they prefer (`op run`, `direnv`, `sops exec-env`,
manual export, etc.).

No `inject` field. The proxy does **string replacement** of placeholder →
real value wherever the placeholder appears in outgoing request headers.
The tool decides how to use its API key — the proxy doesn't need to know.

### Credential lifecycle

`dvm start` boots the VM and proxy with **no credentials**. It can run as
a launchd service with no secret access.

Credentials are resolved implicitly at `dvm exec` / `dvm shell` time:

1. Discover manifest (see below)
2. Read declared env var names from `[secrets.*]`
3. Read their values from the host environment — if any are missing, fail loudly
4. Generate deterministic placeholders (see below)
5. Push placeholder→value mappings to the proxy
6. Inject placeholder env vars into the guest session

No explicit credential commands (`reload`, `unload`, etc.). Every exec/shell
session resolves secrets fresh from the host environment. If a secret's value
changes (e.g., rotated token), the next exec picks it up automatically —
the deterministic placeholder stays the same, the proxy just overwrites the
mapped value.

Different terminal windows can load different projects' credentials
independently.

### Manifest discovery

No directory walking. The manifest is found by, in priority order:

1. `--credentials <path>` flag on `dvm exec` / `dvm shell`
2. `DVM_CREDENTIALS` env var (convenient for shell rc / direnv)
3. `.dvm/credentials.toml` in the current working directory

First match wins. If none found, no credentials are loaded for this session
(the proxy passes traffic through without injection).

Note: running `dvm exec` from a subdirectory of the project will NOT
discover the manifest automatically. Use the `--credentials` flag or
`DVM_CREDENTIALS` env var when not in the project root.

### Deterministic, human-readable, non-guessable placeholders

Format:

```
SANDBOX_CRED_{project}_{secret}_{hmac_suffix}
```

Example:

```
SANDBOX_CRED_nix-darvm_ANTHROPIC_API_KEY_8f3a1b2c9d4e7f01
```

- **`{project}`**: the `project` field from `credentials.toml`, slugified
  (lowercase, non-alphanumeric → `-`, collapse runs)
- **`{secret}`**: the env var name (TOML key), slugified the same way
- **`{hmac_suffix}`**: first 16 hex chars of
  `HMAC-SHA256(host_key, "{project}\x00{secret}")`

Properties:

- **Stable** across restarts — same inputs produce the same placeholder
- **Traceable** — the prefix tells you which project and secret it belongs to
- **Not guessable from the guest** — the HMAC suffix depends on a host-side
  key the guest never sees

### Security model for placeholders

Placeholder disclosure within the guest is **equivalent to credential access**
for the hosts in that secret's scope. Once a guest process has the placeholder
(via env var, subprocess inheritance, logs, or process inspection), it can
use that credential for as long as the mapping is loaded in the proxy.

This is inherent to the design: the guest needs *something* to put in the
request, and whatever that something is acts as a bearer token. Deterministic
placeholders extend this from "one session" to "until host key changes," but
the practical difference is small — most sessions outlast the useful window
for a leaked token anyway.

The HMAC suffix prevents **cross-project** guessing (a process in project A
cannot predict project B's placeholders), not within-session replay.

### Host key

- 32 random bytes, generated once on first use
- Stored at `~/.local/state/dvm/placeholder.key`
- Never mounted into the guest (only `nix-store`, `dvm-state`, and project
  dirs are mounted via VirtioFS)
- If the key is lost/deleted, a new one is generated — all placeholders change,
  but that just means existing shells need a re-exec to pick up new env vars

### Two checkouts of the same project

If someone has the same project checked out at two paths, both checkouts have
the same `credentials.toml` (it's committed — contains no secrets). Same
`project` + secret names → same placeholders. This is intentional: same
project identity, same credentials, same placeholders.

If two loaded projects produce the same placeholder mapped to a **different**
resolved value (different providers resolving to different secrets), that's a
loud error at load time — not silent misbehavior.

### Same project name, different manifests

Two checkouts with the same `project` name but different secret declarations
(e.g., different branches with different `hosts` lists): **last writer wins**.
Each exec pushes its full manifest for that project name. The proxy replaces
the entire set of mappings for that project, not merging with previous state.

This is simple and predictable. If you need two different credential
configurations for the "same" project simultaneously, use different `project`
names.

### Placeholder collision detection

At `load` time, after generating placeholders and resolving values:

1. Check that no placeholder string in the new project matches a placeholder
   in any already-loaded **different** project with a different resolved value.
2. Same placeholder + same value = fine (two checkouts of the same project).
3. Same placeholder + different value = fail with a clear error naming both
   projects and the conflicting secret.
4. Same project name = overwrite (not a collision, just an update).

### Proxy injection model

The proxy switches from mode-based injection (bearer/basic/header) to
**string replacement**: scan outgoing request headers for any known
placeholder string and replace with the real value.

The host list still gates which requests are eligible — a placeholder is only
replaced when the request is destined for a host declared in that secret's
`hosts` list. Placeholders in requests to non-matching hosts are left as-is
(the upstream will reject the bogus token, which is the right failure mode).

**Headers only.** No body or query param scanning in v1.

**HTTPS only.** The proxy refuses to inject credentials into plain HTTP
requests. Replacing a placeholder over unencrypted HTTP would leak the real
credential. If a secret's host is requested over HTTP, the proxy passes the
request through without replacement (the upstream sees the placeholder and
rejects it).

**Single-pass replacement.** Placeholders are replaced in a single pass over
the original header values. This prevents a pathological case where one
secret's resolved value happens to contain another secret's placeholder token.

### Secret lifetime in the proxy

Placeholder→value mappings accumulate in the proxy from successive exec/shell
sessions and remain available until the VM stops. This is fine — the proxy
only uses them when a matching host is requested, and placeholder collision
detection prevents conflicts.

Repeated execs for the same project just overwrite the same mappings (same
deterministic placeholders). No garbage accumulates.

## Changes required

### Swift (host)

1. **`SecretConfig.swift`**
   - New config format: `project` field, `[secrets.<ENV>]` table syntax
   - Drop `InjectMode` enum, `SecretProvider` enum, and `SecretResolver`
   - Secret resolution becomes: read env var by name, fail if missing
   - Replace `generatePlaceholder()` with HMAC-based derivation
   - Add `HostKey` type: load-or-create from `~/.local/state/dvm/placeholder.key`

2. **`Main.swift`**
   - Remove all credential resolution from `dvm start`
   - Move credential resolution to `dvm exec` / `dvm shell` command path
   - Add `--credentials` flag to exec/shell commands
   - Load host key, discover manifest, resolve from env, push mappings to
     proxy, inject placeholder env vars into guest session

3. **`Config.swift`**
   - `credentialManifestPaths` discovery moves from startup to exec time
   - Add `DVM_CREDENTIALS` env var support

### Go (sidecar)

4. **`control.go`**
   - Drop `Inject` type from `SecretRule`
   - Drop `unload` command
   - `Request.ProjectRoot` semantics change: keyed by project name, not path
   - Placeholder collision detection when secrets are pushed
   - Fix: hold mutex through `UpdateSecrets` call to prevent concurrent-load
     lost-update race (existing bug, not new to this design)

5. **`proxy/http.go`**
   - Replace mode-based injection (`rewriteRequest`) with single-pass string
     replacement across request header values
   - Skip injection for plain HTTP requests

## Known edge cases (address during implementation)

- **Replacement in non-auth headers**: a guest can place the placeholder in
  any header (e.g., `User-Agent`). The proxy will replace it if the host
  matches. This is low-risk (the host scope gates it) but could be restricted
  to an allowlist of auth-related headers if needed later.
- **Subdirectory discovery**: `dvm exec` from a project subdirectory won't
  find the manifest. Users must use `--credentials` or `DVM_CREDENTIALS`.
  Could add walking later if this proves painful.
- **Concurrent exec sessions**: two terminals pushing secrets for different
  projects simultaneously. The control socket must serialize these to avoid
  the lost-update race (see control.go fix above).

## Not in scope

- Central config (`~/.config/dvm/config.toml`) for secrets — project-local only
- Per-secret provider mechanism — the host environment is the universal interface
- Wildcard host matching (`*.amazonaws.com`)
- Basic auth injection (placeholder gets base64-encoded, can't string-replace)
- `SSL_CERT_FILE` env var injection
- Explicit credential management commands (reload, unload)
- Per-session capability narrowing
- Directory walking for manifest discovery
