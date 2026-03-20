---
# nix-darvm-27hf
title: Implement project-local secrets
status: completed
type: feature
priority: normal
created_at: 2026-03-20T18:56:40Z
updated_at: 2026-03-20T18:57:34Z
---

Umbrella bean for the project-local secrets mechanism described in docs/project-local-secrets.md.

No backward compatibility with current credentials.toml format — clean break.

Three implementation slices:
1. `nix-darvm-6e9t` — Go sidecar: string replacement + collision detection
2. `nix-darvm-g5dm` — Swift: HMAC placeholders + exec-time credential resolution (blocked by 6e9t)
3. `nix-darvm-qkg2` — Swift: manifest discovery + CLI wiring (blocked by g5dm)

Design doc: docs/project-local-secrets.md
