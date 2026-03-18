# Credentials Proxy V1 Implementation Brief

## Purpose

Describe the smallest `nix-darvm`-native implementation that satisfies the V1
scope in [`docs/credentials-proxy-v1-scope.md`](./credentials-proxy-v1-scope.md).

This document is intentionally concrete. It answers:

- what to build
- what not to build
- how the pieces fit into the current host/guest architecture
- which ideas are worth borrowing from existing tools

## Design Evolution

This design did not start here.

We first explored:

- adopting an existing credentials tool wholesale
- building a fully first-party reverse-proxy-only broker

What we learned:

- none of the reviewed tools fit the full `nix-darvm` model closely enough to
  adopt as-is
- a reverse-proxy-only V1 would simplify policy enforcement, but it would push
  too much day-to-day configuration burden onto guest tools and make host/guest
  workflow switching awkward

The deciding tradeoff was ergonomics.

For this project, V1 should optimize for:

- tools inside the VM using normal upstream URLs
- minimal per-tool override burden
- easy switching between host and guest work environments

That points to a forward-proxy-based V1, but not a hand-rolled one.

The result is a hybrid design:

- `darvm` owns manifest, policy, reload, provider resolution, and lifecycle
- an existing proxy core owns forward-proxy mechanics

## Recommendation

Build a first-party `darvm` credentials control plane around an existing
forward-proxy core.

Recommended proxy core: `nono-proxy`.

Do not adopt another project as the full runtime.

Existing tools are useful design input, but none matches the required shape
closely enough:

- shared long-lived VM
- multiple projects loaded at once
- repo-scoped manifest
- explicit reload
- no raw secret exposure to guest workloads
- narrow V1 focused on brokered outbound HTTP(S)

The current recommendation is:

- `darvm` owns project manifests, reload, provider references, and lifecycle
- `nono-proxy` owns forward proxying, CONNECT handling, streaming, and request
  forwarding
- V1 accepts a deliberate policy tradeoff for HTTPS CONNECT traffic:
  host-level allowlists, not path-level enforcement

## Design Summary

Implement a host-side `CredentialBroker` plus one or more host-side
`nono-proxy` processes, exposed to the guest through `darvm` transport glue.

The host owns:

- manifest loading
- provider resolution
- policy validation
- proxy lifecycle
- audit logging

The guest sees:

- stable local proxy endpoints
- standard proxy environment variables where possible
- optional compatibility wrappers where needed

The guest never receives raw secret values.

## Operating Model

### Shared VM

The VM is long-lived and may serve multiple projects at once.

Therefore:

- credentials are not tied to `dvm start`
- project policy must be loaded independently
- every request must resolve to a specific project

The effective authorization unit is:

```text
(project_root, capability_name)
```

### Explicit reload only

Manifests are loaded into the running broker explicitly.

There is no file watching and no automatic hot reload.

## What To Build

### 1. Repo manifest

Each project may contain:

```text
.dvm/credentials.toml
```

The manifest defines declared capabilities for that project.

The manifest must not contain raw secret values.

### 2. Host-side broker registry

The broker keeps a registry of loaded project manifests:

- project root
- manifest path
- manifest hash
- loaded timestamp
- capability definitions

Reload updates only one project entry atomically.

### 3. Host-side forward proxy instances

Expose one or more host-side `nono-proxy` instances for V1.

These proxies are the only supported request path in V1.

`darvm` manages them and bridges them into the guest.

The simplest V1 shape is:

- one proxy instance per active project
- the proxy instance is configured from that project's loaded manifest
- explicit reload restarts the corresponding proxy instance atomically

### 4. Compatibility wrappers

Because many third-party clients do not support custom headers or custom auth
hooks, provide wrapper commands that configure them to use the local proxy.

Examples:

- `dvm run-credentialed --project . --tool claude-code -- claude-code`
- `dvm run-credentialed --project . --tool codex -- codex`
- `dvm run-credentialed --project . --tool gemini-cli -- gemini`

These wrappers may set:

- `HTTP_PROXY`
- `HTTPS_PROXY`
- tool-specific proxy toggles
- dummy tokens when a client insists on one

They must never expose real credentials.

## Manifest Schema

Use a simple TOML format.

Example:

```toml
version = 1

[capabilities.github]
type = "http"
description = "GitHub API access for this repo"

[capabilities.github.provider]
type = "keychain"
service = "github.com"
account = "work-bot"

[capabilities.github.allow]
hosts = ["api.github.com"]
methods = ["GET", "POST", "PATCH"]
path_prefixes = ["/repos/unbody/", "/user"]

[capabilities.github.limits]
max_request_bytes = 1048576
max_response_bytes = 10485760

[capabilities.openai]
type = "http"
description = "OpenAI API access"

[capabilities.openai.provider]
type = "env"
name = "OPENAI_API_KEY"

[capabilities.openai.allow]
hosts = ["api.openai.com"]
methods = ["POST"]
path_prefixes = ["/v1/"]
```

### Schema rules

- `version` is required
- only `type = "http"` exists in V1
- `provider` is required
- `allow.hosts` is required
- `allow.methods` is required
- `allow.path_prefixes` is optional but strongly recommended
- limits are optional but recommended

### Supported provider references in V1

#### `keychain`

```toml
type = "keychain"
service = "github.com"
account = "work-bot"
```

#### `env`

```toml
type = "env"
name = "OPENAI_API_KEY"
```

#### `command`

```toml
type = "command"
argv = ["op", "read", "op://vault/item/field"]
```

`command` is host-controlled and explicit. Guest input must never affect it.

## Control Plane

Add these commands to `dvm`:

### `dvm credentials reload [path]`

Load or replace the manifest for one project.

Behavior:

1. resolve project root
2. read `.dvm/credentials.toml`
3. validate the manifest
4. validate all provider references
5. atomically swap the broker entry for that project

If validation fails, keep the old config active.

### `dvm credentials list [path]`

List capabilities for one project.

### `dvm credentials show <capability> [path]`

Show resolved policy for one capability.

### `dvm credentials status`

List loaded projects and manifest hashes.

Example:

```text
Loaded credential manifests:

/Users/gaborkerekes/unbody/nix-darvm
  manifest: .dvm/credentials.toml
  hash: 8b1f2c0d
  capabilities: github, openai
```

## Guest-Facing Request Model

### V1 model

V1 is forward-proxy-first.

The intended UX is:

- tools keep using normal upstream URLs
- wrapper commands set proxy-related environment only inside the guest session
- `darvm` routes the guest to the correct project-scoped proxy instance

Provider-compatible local base URL mode is no longer the primary V1 design.
It may still be used for specific clients later, but it is not the core path.

## Third-Party Client Strategy

### First-class V1 targets

- `claude-code`
- `codex`
- `gemini-cli`

### Expected integration style

#### `claude-code`

Prefer:

- wrapper command
- proxy config
- dummy token if the client insists on one

#### `codex`

Prefer:

- wrapper command
- proxy config
- fake token in guest-visible config if required

#### `gemini-cli`

Prefer:

- wrapper command
- proxy config
- fake token if required by the client

### General rule

The wrapper may expose:

- a proxy URL
- a session routing token
- a dummy API key

The wrapper must not expose:

- the real upstream secret
- a reusable provider credential

## Broker Behavior

### Validation

Before sending any outbound request, the broker validates:

- project is loaded
- scheme is `http` or `https`
- destination host is allowed
- request size is within limits

For V1, policy differs by transport visibility:

- plain `http`: host, path prefix, and method may all be enforced
- `https` over CONNECT: enforce host-level policy only unless and until `darvm`
  intentionally adopts TLS interception

This is a deliberate V1 tradeoff for ergonomics.

### Provider resolution

After policy validation, the broker resolves the credential from the configured
provider.

Provider errors must preserve failure context without leaking secret data.

### Auth injection

V1 handlers:

- bearer token
- basic auth
- custom static header

The handler injects auth into the proxy configuration or outbound request path
after validation.

### Outbound request execution

`nono-proxy` performs the forwarded network request.

`darvm` must not hand a signed request back to the guest to replay.

### Response handling

Return:

- status code
- response headers
- response body stream

Do not log or persist bodies by default.

Do not attempt response credential redaction in V1.

## Failure Semantics

Fail closed.

Examples:

```text
Credential manifest reload failed:
provider env OPENAI_API_KEY is not set on host
```

```json
{
  "error": "capability_denied",
  "message": "host api.stripe.com is not allowed for capability github"
}
```

```json
{
  "error": "unknown_project",
  "message": "no credential manifest loaded for project /Users/admin/src/repo-a"
}
```

If reload fails, keep the previous manifest active.

If a request is invalid, do not fall back to direct egress.

## Audit Model

For each brokered request, log:

- project root
- capability
- destination host
- method
- status code
- request bytes
- response bytes
- failure category

Do not log:

- secret values
- auth headers
- request bodies by default
- response bodies by default

## Where This Fits In nix-darvm

### Host side

Add:

- a host-side credential control plane in `darvm`
- a managed `nono-proxy` child process per active project or capability set
- a bridge from guest access to host-side proxy listeners

Likely integration points:

- [`host/Sources/Main.swift`](../host/Sources/Main.swift)
- [`host/Sources/ControlSocket.swift`](../host/Sources/ControlSocket.swift)
- [`host/Sources/Config.swift`](../host/Sources/Config.swift)
- [`host/Sources/VsockDaemonBridge.swift`](../host/Sources/VsockDaemonBridge.swift)

### Guest side

Expose the host-side proxy to the guest with minimal extra machinery.

The likely V1 pattern is:

- host-side `nono-proxy` listens on local TCP
- `darvm` bridges that listener to the guest over vsock
- guest tools point at the bridged proxy endpoint

Likely integration points:

- [`host/Sources/VsockDaemonBridge.swift`](../host/Sources/VsockDaemonBridge.swift)
- [`guest/image/vsock-bridge`](../guest/image/vsock-bridge)

### Recommended transport choice

Do not start with gRPC or a custom streaming RPC.

V1 should prefer:

- a host-side managed proxy process
- raw TCP bridging over vsock
- restart-on-reload

This keeps the transport boring and lets `darvm` reuse an existing proxy core.

## Thin Implementation Slices

### Slice 1: Manifest loader and registry

Build:

- TOML parser
- manifest validation
- in-memory registry keyed by project root
- `dvm credentials reload`
- `dvm credentials status`

No network path yet.

Success condition:

- can load multiple projects into one running broker
- atomic reload works

### Slice 2: Host-side `nono-proxy` management

Build:

- process launch and shutdown
- config generation from one loaded manifest
- restart-on-reload
- health checks

No guest wiring yet.

Success condition:

- host can launch a proxy instance for one project and restart it after reload

### Slice 3: Guest bridge

Build:

- host TCP to guest vsock bridge
- one guest-visible proxy endpoint
- wrapper command that sets proxy env for one tool

Success condition:

- one real tool can reach an authenticated upstream through the managed proxy

### Slice 4: Provider resolution and policy generation

Build:

- env provider
- keychain provider
- optional command provider
- manifest-to-proxy-config translation

Success condition:

- `darvm` can resolve one project's credentials and generate a working proxy config

### Slice 5: Tool wrappers

Start with one real tool, preferably the one that matters most in daily use.

Good candidates:

- `claude-code`
- `codex`

Success condition:

- the tool can make authenticated provider requests through the proxy without
  seeing the real key

## Borrowed Ideas

### From `nono`

Borrow:

- forward proxy mechanics
- CONNECT support
- practical third-party client integration patterns
- DNS rebinding and outbound host protections

Do not copy:

- full sandbox runtime
- global profiles and hook installation model

### From `matchlock`

Borrow:

- placeholder substitution mindset where useful
- policy thinking around host-side enforcement

Do not copy:

- microVM lifecycle ownership
- host-global sandbox state model

### From `agentsecrets`

Borrow:

- auth injection handlers
- response redaction approach

Do not copy:

- cloud/workspace/account runtime model
- env injection as the main compatibility path

## Open Questions

### 1. Proxy instance granularity

Should V1 run:

- one proxy per active project
- one proxy per capability set
- one proxy with internal routing

Recommendation:

start with one proxy per active project unless that creates unacceptable port
management overhead.

### 2. Wrapper UX

Should wrappers be:

- `dvm run-credentialed --tool ...`
- tool-specific aliases such as `dvm claude`

Recommendation:

start with one generic wrapper command and add aliases later if needed.

### 3. Provider availability checks

Should `reload` require providers to be immediately resolvable?

Recommendation:

yes for V1. Fail at reload time when possible.

### 4. Upstream coordination

Should `darvm` depend on `nono-proxy` as-is, vendor it, or fork it?

Recommendation:

talk to the maintainer before committing to the dependency. In particular:

- public API stability
- runtime config generation expectations
- multiple instance support
- whether reload or routing hooks are realistic upstream

## Non-Goals For This Implementation

- private dependency fetching
- cloud-provider control-plane support
- database connectivity
- SSH or generic TCP proxying
- universal support for every third-party client

The implementation should stay narrow enough that it can ship as a real V1
instead of collapsing into a generalized secret platform.
