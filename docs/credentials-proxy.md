# Credentials Proxy Design

See [`docs/credentials-proxy-v1-scope.md`](./credentials-proxy-v1-scope.md) for
the intentionally narrower product boundary agreed for the first version.

## Goal

Allow workloads inside the guest VM to use host-held credentials without ever receiving the raw secret value.

In this model, the guest gets a capability to perform a bounded action, not a capability to read a secret.

## Problem Statement

Today `nix-darvm` has two relevant trust boundaries:

- Host-side code owns VM lifecycle, config loading, and vsock bridges.
- Guest-side agents execute arbitrary commands as the normal VM user.

The current guest to host escape hatch is [`HostCommandBridge`](../host/Sources/HostCommandBridge.swift), which allowlists host binaries and forwards arbitrary arguments from the guest. That is too coarse for secrets:

- Any guest process can connect to the bridge.
- Arguments are not policy-checked beyond the binary name.
- Commands can return secret material over stdout/stderr.
- Auditability is at the process level, not the credential use level.

For the same reason, these must remain out of scope:

- Mounting secret files into the guest
- Passing secrets via env vars
- A `GetSecret(name) -> value` RPC
- Using `dvm-host-cmd` as a secret lookup workaround

## Threat Model

We assume:

- The guest user and agent workloads are untrusted with respect to host secrets.
- The guest may be able to make arbitrary network requests.
- A compromised guest workload may try to coerce the host into revealing or misusing credentials.

We want:

- No raw secret bytes sent to the guest
- Deny-by-default access to credentials
- Narrow policies per credential and per target
- Clear audit logs for every credentialed action
- Fail-closed behavior when policy, provider lookup, or transport setup fails

We do not fully solve:

- A malicious guest using an allowed capability for an allowed target
- Screen scraping or token theft from an already-authenticated remote service response
- Exfiltration through a protocol that fundamentally requires the client to possess the raw secret

That last point matters: some integrations can be proxied safely, others cannot. The design should support only protocols where the host can apply credentials without revealing them.

## Design Summary

Add a dedicated host-side `CredentialBroker` plus a guest-visible proxy path.

The broker is policy-aware and secret-aware.
The guest-facing path is policy-aware but secret-blind.

High-level flow:

1. Host starts `CredentialBroker` with declarative credential policies.
2. Guest receives only proxy endpoints and capability metadata.
3. Guest sends a request through the proxy for an allowed capability.
4. Host resolves the credential from its provider, applies it to the outbound request path, forwards the request, and streams back the response.
5. Raw secret bytes never cross the host/guest boundary.

For the current V1 direction, the proxy transport should be built around an
existing forward-proxy core rather than a fully custom transport stack.

## Architecture

### 1. Host-side `CredentialBroker`

Lives in the host process alongside the existing control plane.

Responsibilities:

- Load credential policy from declarative config
- Resolve secrets from host-only providers
- Validate outbound requests against per-capability policy
- Apply auth material to supported protocols
- Emit structured audit logs with redaction

The broker should not reuse `HostCommandBridge`. It needs typed policy enforcement, redaction, and per-capability semantics.

### 2. Guest-facing proxy path

Expose guest-visible proxy endpoints for supported credentialed actions.

The first-class interface should be a local HTTP(S) proxy path because it maps
cleanly to common agent activity and preserves better day-to-day ergonomics for
third-party tools:

- REST APIs
- LLM provider APIs

For V1, prefer forward-proxy semantics over capability-specific reverse-proxy
URLs. This keeps guest tools closer to their normal host configuration and makes
switching between host and guest workflows less awkward.

The current recommended shape is:

- `darvm` owns manifest loading, policy, reload, provider resolution, and lifecycle
- a managed proxy core handles forward-proxy mechanics, CONNECT, streaming, and forwarding
- guest wrappers set proxy-related environment only inside the guest session

The guest still never receives the final `Authorization` header value, client
cert, or signing key.

### 3. Dedicated Typed Transport

Do not overload:

- the raw `dvm-host-cmd` protocol
- the existing guest `Agent.Exec` RPC

But also do not assume V1 needs a custom gRPC transport.

The current preferred direction is simpler:

- run a managed host-side forward proxy process
- bridge guest access to that process over vsock
- keep `darvm` focused on config, policy, and lifecycle

That lets `darvm` reuse existing proxy mechanics instead of hand-rolling them.

### 4. Capability Model

A capability is the unit of authorization.

Example:

- `github-api`
- `openai-api`
- `anthropic-api`

Each capability contains:

- protocol handler type
- secret provider reference
- allowed destination hosts
- optional allowed path prefixes
- optional allowed methods
- optional header rewrite rules
- request and byte limits
- audit label

Example policy sketch:

```nix
dvm.credentials.github-api = {
  handler = "http-bearer";
  provider = {
    type = "keychain";
    service = "github.com";
    account = "work-bot";
  };
  allow = {
    hosts = [ "api.github.com" "uploads.github.com" ];
    methods = [ "GET" "POST" "PATCH" ];
    pathPrefixes = [ "/repos/unbody/" "/user" ];
  };
};
```

The guest can use `github-api`, but it cannot ask for the token itself.

## Supported Handlers

Only support handlers where the host can apply credentials directly.

### Phase 1: HTTP auth injection

Primary initial handler:

- `http-bearer`
- `http-basic`
- `http-header`

The host injects auth into the outbound request path after policy validation.

This covers the biggest class of agent integrations with the least protocol complexity.

### Phase 2: SSH agent style signing

Support an SSH signing relay, not raw private key export.

That mirrors how SSH agent forwarding works: the guest can request signatures, but cannot read the private key material.

### Phase 3: Cloud signing adapters

Add explicit adapters only where the protocol allows host-side signing without exposing reusable secrets:

- AWS SigV4
- GCP access-token minting
- short-lived OAuth token exchange

Each adapter should be separate and typed. Do not collapse them into a generic "run provider command and paste result into request" mechanism.

## Secret Providers

Providers are host-only. The guest never talks to them directly.

Initial provider types:

- macOS Keychain item lookup
- environment variable inherited by `dvm start`
- external command executed on the host

Provider rules:

- Secret values stay in host memory only
- Provider stderr must be preserved in final failure context
- Provider command output must be parsed strictly
- Provider commands must be opt-in and explicit, not guest-controlled

The external command provider is acceptable only as an operator-configured backend. It must not be influenced by guest input.

## Configuration Model

Credential policy should be repo-scoped and explicitly loaded into the running
broker.

The V1 implementation brief now standardizes on a repo manifest:

```text
.dvm/credentials.toml
```

and control-plane commands such as:

- `dvm credentials reload [path]`
- `dvm credentials list`
- `dvm credentials show <capability>`
- `dvm credentials status`

Guest-visible environment should expose only safe proxy information and optional
dummy tokens. No real secret-bearing environment variables.

## Request Flow

For an HTTP capability:

1. A project manifest is explicitly loaded into the running host-side broker.
2. `darvm` starts or restarts the corresponding managed proxy process.
3. A guest wrapper points the tool at the project's proxy endpoint.
4. The proxy receives the outbound request.
5. `darvm`-managed policy validates the destination and allowed request shape.
6. The broker resolves the secret from the configured provider.
7. The proxy forwards the request with host-side auth injection.
8. The proxy streams the response back to the guest.
9. The broker emits an audit event with capability, destination, method, response status, and byte counts.

The guest only sees the upstream response, never the secret or the final outbound auth material.

## Why Forward Proxy For V1

We initially explored a reverse-proxy-first design because it makes path and
method enforcement straightforward.

We are currently favoring a forward-proxy-first V1 because:

Reasons:

- guest tools can keep using normal upstream URLs
- fewer per-tool base URL overrides are needed
- host/guest workflow switching is smoother
- we can reuse an existing proxy core instead of writing transport code from scratch

Tradeoff:

- for HTTPS CONNECT traffic, host-level allowlists are realistic in V1
- path-level enforcement for HTTPS would require deliberate TLS interception later

## Logging and Redaction

Credential use must be observable without leaking secrets.

Audit log fields:

- timestamp
- run id
- capability
- handler type
- destination host
- method
- status code
- request bytes
- response bytes
- failure reason category

Do not log:

- auth headers
- provider output
- request bodies by default
- response bodies by default

When failures happen, preserve context without printing secrets. For example:

- `provider keychain lookup failed: item not found`
- `request denied: host api.stripe.com not allowed for capability github-api`

Do not attempt full response redaction in V1. That is too complex for the first
cut and should not silently degrade behavior.

## Failure Semantics

This service must fail loudly and closed.

If any step fails:

- unknown capability
- provider resolution failure
- policy mismatch
- broker transport unavailable
- upstream timeout

the request fails with an explicit error. There is no fallback to direct egress, mounted files, or `HostCommandBridge`.

## Non-Goals

- A generic "fetch secret" API
- Making every protocol proxyable
- Transparent interception of all guest egress
- Backward compatibility for workflows that currently depend on reading env vars or files

If a workflow fundamentally requires the raw secret in guest memory, it is not compatible with this design and should be rejected explicitly.

## Integration Points In This Repo

This design fits the current codebase here:

- [`host/Sources/Main.swift`](../host/Sources/Main.swift) already starts host-side vsock services and is the right place to start the broker.
- [`host/Sources/HostCommandBridge.swift`](../host/Sources/HostCommandBridge.swift) demonstrates the current guest to host bridge, but should not be extended for secrets.
- [`host/Sources/Config.swift`](../host/Sources/Config.swift) already documents why writable guest access to host config is dangerous.
- [`host/Sources/VsockDaemonBridge.swift`](../host/Sources/VsockDaemonBridge.swift) is relevant because V1 likely wants simple proxy bridging rather than a custom RPC stack.
- [`guest/host-cmd/main.go`](../guest/host-cmd/main.go) is intentionally too primitive for secret handling.

## Rollout Plan

### Step 1: Config and data model

- Add repo-scoped `.dvm/credentials.toml`
- Add explicit reload commands
- Reject unsupported handler/provider combinations at reload time

### Step 2: Host broker skeleton

- New host-side broker service
- Project registry
- Managed proxy process lifecycle
- Structured audit logging

### Step 3: Forward proxy integration

- Integrate a forward-proxy core
- Implement `http-bearer` first
- Add host allowlists and request validation
- Add integration tests against a local mock upstream

### Step 4: Guest UX

- Provide wrapper commands and stable proxy endpoints
- Document how guest tools opt in
- Make unsupported direct-secret workflows fail clearly

### Step 5: Additional handlers

- SSH signing relay
- Cloud-specific signing adapters

## Open Questions

- Should capability access be global to the guest, or should `dvm exec` sessions receive a narrower per-session capability set?
- Do we want the host broker to enforce DNS resolution and IP allow/deny checks to prevent host-pattern bypasses?
- Should response-body size limits be hard-fail or stream-cut with an explicit error trailer?
- How much guest-visible capability metadata is acceptable without leaking operator intent?

## Recommended First Slice

Build only this first:

- repo-scoped manifest loading
- explicit reload
- one managed forward proxy instance
- bearer token injection
- host allowlists for HTTPS
- structured audit logs

That is the smallest useful system that enforces the core rule: agents can use credentials, but they cannot read them.
