# E2E Testing Flight Plan

Quick reference for manual e2e testing of DVM with the credential proxy.

## 0. Prerequisites

```bash
just build          # Swift + Go + netstack
just dvm init       # Base image (skip if any darvm-* exists)
```

## 1. Host config — `~/.config/dvm/config.toml`

```toml
[mounts.mirror]
dirs = ["/path/to/project-a", "/path/to/project-b"]
transport = "nfs"

[mounts.home]
dirs = ["~/.claude", "~/.unison"]

flake = "/path/to/your-dvm-flake"   # or omit to use PWD/flake.nix
```

## 2. Secrets — `<project>/.dvm/credentials.toml`

```toml
version = 0
project = "my-project"

[proxy.OPENAI_KEY]
hosts = ["api.openai.com"]

[proxy.GITHUB_TOKEN]
hosts = ["api.github.com", "uploads.github.com"]
from.command = ["op", "read", "op://Engineering/GitHub/token"]
```

The manifest declares which guest env vars to inject, which hosts they apply
to, and optionally how the host resolves them. If `from` is omitted, DVM reads
the same-named host env var at exec time. Real values are never stored in the
manifest.

## 3. Launch

```bash
just dvm start      # builds closure -> activates -> sidecar + CA always start -> VM running
```

The credential proxy (netstack sidecar) is always-on. CA cert is installed
in the guest trust store on every boot. No credentials are loaded at startup —
they're pushed per-exec.

## 4. Exec with credentials

```bash
# Credentials discovered from .dvm/credentials.toml in cwd:
OPENAI_KEY=sk-real-key just dvm exec -- curl -v https://api.openai.com/v1/models
# Guest sees OPENAI_KEY=SANDBOX_CRED_my-project_openai-key_<hmac>
# Proxy replaces the placeholder with sk-real-key in the HTTPS request

# Explicit manifest path:
just dvm exec --credentials /path/to/credentials.toml -- env

# Via env var:
DVM_CREDENTIALS=/path/to/credentials.toml just dvm exec -- env
```

If the manifest uses `from.command`, `dvm exec` resolves that secret directly
and no host shell export is needed for that entry.

Discovery priority: `--credentials` flag > `DVM_CREDENTIALS` env > `.dvm/credentials.toml` in cwd.
No directory walking. Explicit sources fail loudly on missing files.

## 5. Verify proxy

```bash
just dvm exec -- curl -v https://api.openai.com/v1/models
# Authorization: Bearer <real-key> injected via placeholder replacement
# Guest never sees the real secret — only the SANDBOX_CRED_... placeholder

just logs           # stream netstack + agent logs
just dvm status     # phase, mounts, services
```

HTTP requests pass placeholders through unmodified (replacement is HTTPS-only).

## 6. Switch config on live VM

```bash
just dvm switch     # rebuilds closure, activates in-place, no reboot
```

Works even mid-boot (waits for running phase, up to 120s).

## 7. Teardown

```bash
# Ctrl-C in the start terminal, or:
just dvm stop
```

## Key invariants

- **Fail closed** — if netstack crashes, networking is down (no silent fallback to NAT)
- **Image stability** — hash only changes when `guest/image-minimal/` changes; code/module changes go through `dvm switch`
- **HTTPS only** — placeholder replacement only happens on HTTPS requests; HTTP passes through as-is
- **Exec-time resolution** — credentials are read from host env and pushed to sidecar on each `dvm exec`/`dvm ssh`, not at VM startup
- **Optional explicit sources** — `from.command` can resolve individual secrets without pre-exporting them in the host shell
