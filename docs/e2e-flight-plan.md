# E2E Testing Flight Plan

Quick reference for manual e2e testing of DVM with the credential proxy.

## 0. Prerequisites

```bash
just build          # Swift + Go + netstack
just dvm init       # Base image (skip if any darvm-* exists)
```

## 1. Host config — `~/.config/dvm/config.toml`

```toml
[mounts]
mirror = ["/path/to/project-a", "/path/to/project-b"]

[host]
commands = ["brew", "git"]

flake = "/path/to/your-dvm-flake"   # or omit to use PWD/flake.nix
```

## 2. Secrets — `<project>/.dvm/credentials.toml`

```toml
version = 1

[[secrets]]
name = "OPENAI_KEY"
hosts = ["api.openai.com"]
inject = "bearer"
provider = { type = "env", name = "OPENAI_API_KEY" }

[[secrets]]
name = "CUSTOM_HEADER"
hosts = ["internal.api.com"]
inject = { type = "header", name = "X-Api-Key" }
provider = { type = "command", argv = ["op", "read", "op://vault/item/key"] }
```

Each mirror dir is scanned for `.dvm/credentials.toml`. No host overlap between projects.

Provider types: `env`, `command`, `keychain` (macOS Keychain).

## 3. Launch

```bash
just dvm start      # builds closure -> activates -> proxy starts if creds exist -> VM running
```

Proxy auto-starts when any project has `.dvm/credentials.toml`. CA cert is
injected into the guest trust store via nix-darwin activation.

## 4. Parallel projects

All mirror dirs are mounted via VirtioFS. Work in any from guest:

```bash
just dvm exec -- ls /path/to/project-a
just dvm exec -- ls /path/to/project-b
```

## 5. Switch config on live VM

```bash
just dvm switch     # rebuilds closure, activates in-place, no reboot
```

Works even mid-boot (waits for running phase, up to 120s).

## 6. Verify proxy

```bash
just dvm exec -- curl -v https://api.openai.com/v1/models
# Authorization: Bearer <real-key> injected; guest never sees the secret
just logs           # stream netstack + agent logs
just dvm status     # phase, mounts, services
```

## 7. Teardown

```bash
# Ctrl-C in the start terminal, or:
just dvm stop
```

## Key invariants

- **Fail closed** — if netstack crashes, networking is down (no silent fallback to NAT)
- **Image stability** — hash only changes when `guest/image-minimal/` changes; code/module changes go through `dvm switch`
- **Snapshots** — `just snapshot` / `just restore` for quick save/restore cycles
