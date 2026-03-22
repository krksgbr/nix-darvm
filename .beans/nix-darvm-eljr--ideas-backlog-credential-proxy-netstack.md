---
# nix-darvm-eljr
title: Ideas backlog — credential proxy, netstack & host actions
status: todo
type: task
created_at: 2026-03-20T13:41:45Z
updated_at: 2026-03-20T13:41:45Z
---

Meta-bean tracking unspecified ideas that need more thought before becoming plans. Each item has a real-world motivation — why a user or developer would care.

## Ideas

### Integration test harness for the proxy

Zero unit/integration tests exist for the proxy code. Every change requires a full manual e2e cycle: start VM, curl endpoints, eyeball output. This is slow (~2 min turnaround) and fragile — the HTTP/2 regression we caught during the stdlib refactor (closeNotifyConn hiding `*tls.Conn`) would have been caught instantly by an automated test with a real HTTP/2 client.

**Who cares:** Developer. Faster feedback loop, fewer regressions slipping through manual testing.

### Wildcard host matching

Host matching is exact-only (`"api.anthropic.com"`). Users with services spanning many subdomains (e.g. `*.amazonaws.com` for S3, `*.openai.com`) must list every subdomain individually. Easy to miss one, and the config becomes verbose.

**Who cares:** User. Less config boilerplate, fewer "why isn't my credential being injected?" moments.

### SSL_CERT_FILE env var injection

The MITM CA is installed in the system trust store, but some tools (older Python, custom curl builds, certain Node versions) ignore it and require `SSL_CERT_FILE` or `NODE_EXTRA_CA_CERTS` pointing at the CA cert file. Without this, credential injection silently fails for those tools — the TLS handshake fails before the proxy ever sees the request.

**Who cares:** User. Mysterious TLS errors in specific tools with no obvious connection to the credential proxy.

### Structured metrics / observability

No visibility into proxy behavior at runtime. Can't tell how many requests were intercepted vs passed through, cert cache hit rate, upstream connection failures, or latency overhead. Debugging requires adding ad-hoc `log.Printf` and rebuilding.

**Who cares:** Developer (debugging) and eventually user (understanding what the proxy is doing with their traffic).

## Host actions — future hardening ideas

Ideas from first-principles design review (Codex + Gemini, 2026-03-22). The v1 host actions redesign uses an immutable nix-built handler manifest with stdin/stdout handlers. These are evolution paths beyond v1.

### Per-action macOS sandbox profiles

Use `sandbox-exec` to run each handler in a tailored macOS sandbox profile. A `notify` handler gets access to `osascript` and nothing else; a `git-credential` handler gets network but no filesystem. Deny-by-default per action, not just scrubbed env.

**Who cares:** Security. Limits blast radius if a handler has a bug or is exploited. The scrubbed-env approach in v1 is good but doesn't prevent a handler from reading arbitrary host files.

**Difficulty:** High. Apple's sandbox profile syntax (`.sb`) is arcane and largely undocumented. Profiles are brittle across macOS versions.

### Cryptographic capability tokens

At nix build time, mint Ed25519-signed tokens for each allowed action, bake them into the guest nix store. Guest must present the token to invoke an action. The token IS the authentication — sidesteps vsock's lack of caller auth.

**Who cares:** Security. Any guest process can currently invoke any declared action by speaking the vsock protocol. Tokens don't fix per-process auth (any process that can read the nix store can read the token) but they do create an unforgeable, auditable link between "what was declared at build time" and "what's being invoked at runtime." Also enables: token expiry, boot-epoch binding, revocation.

**Origin:** Independently proposed by both Codex and Gemini. Qubes OS qrexec uses a similar pattern (policy evaluated by dom0 at invocation time).

### WebAssembly plugin handlers

Compile handlers to Wasm, run in a Wasm runtime (Wasmtime) on the host. WASI provides deny-by-default sandboxing — handlers can only access explicitly granted capabilities (specific dirs, network, specific host APIs). Memory-safe by construction.

**Who cares:** Security (strongest isolation model), portability (Wasm modules are arch-independent). Eliminates the class of bugs where a handler escapes to the host OS.

**Difficulty:** High. Requires integrating a Wasm runtime into the Swift host binary. macOS-native APIs (notifications, AppleScript) need custom WASI host functions. Tooling for Swift+Wasm is immature. Users can't write quick bash scripts — must compile to Wasm.

### Argument narrowing at the bridge level (qrexec-style)

Qubes OS qrexec supports `+argument` suffixes on service names, enabling per-argument policy: allow `open-url+https://github.com/*` but deny `open-url+file:///`. This lets the bridge enforce coarse argument constraints before the handler even runs.

**Who cares:** Defense in depth. Handlers validate their own input in v1, but bridge-level narrowing catches entire categories of bad input before reaching handler code. Most useful for broad actions like `open-url` or `git`.

**Difficulty:** Low-medium. Simple pattern matching at the bridge. The design question is where the patterns live (per-action config in nix).
