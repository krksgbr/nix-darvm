# Credentials Proxy V1 Scope

## Purpose

Define the initial product boundary for the credentials proxy.

This document is intentionally narrower than the full architecture in
[`docs/credentials-proxy.md`](./credentials-proxy.md). The goal is to solve the
real development workflow first without designing a universal credentials system.

Implementation details live in
[`docs/credentials-proxy-v1-implementation.md`](./credentials-proxy-v1-implementation.md).

## Operating Context

V1 is for development and prototyping inside a shared long-lived VM.

Important context:

- The VM is not project-scoped.
- A single VM may be used for multiple projects at once.
- `dvm start` is not the project boundary and may run under launchd.
- Credential policy must therefore be loaded and resolved per project, not per VM start.
- Agents must never read raw secrets.

## Product Statement

V1 supports brokered, authenticated outbound HTTP(S) requests from the guest to
explicitly approved non-cloud destinations.

That is the whole product boundary for V1.

## In Scope

### 1. LLM provider access

Tools and scripts inside the guest may call LLM providers through the broker.

Examples:

- `claude-code`
- `codex`
- `gemini-cli`
- custom scripts using OpenAI, Anthropic, Gemini, or OpenRouter APIs

### 2. Authenticated outbound HTTP(S) to non-cloud APIs

Guest workloads may call approved HTTP(S) endpoints with broker-applied credentials.

Examples:

- GitHub Issues / PR metadata APIs
- Linear, Jira, Slack, Notion
- your own dev or staging HTTP APIs

This includes selected write actions when explicitly allowed by policy.

Examples of allowed writes:

- post a GitHub comment
- create a Linear ticket
- send a Slack message

The rule is not "read-only only". The rule is "only the exact hosts, paths, and
methods explicitly allowed by the project manifest".

## Deferred

These are not part of V1, but the architecture should leave room for them later.

### 1. Private dependency / artifact access

This includes authenticated package registries, private artifacts, and read-only
private source dependencies.

Reason for deferral:

- useful, but not an everyday need
- existing projects already have most private dependencies fetched
- not needed to validate the core V1 architecture

### 2. Cloud-provider control-plane APIs

Examples:

- GCP APIs via `gcloud` or SDKs
- AWS / Azure control-plane APIs

Reason for deferral:

- these flows are often still HTTP(S), but the permissions are much more sensitive
- they need separate review and tighter scoping than generic API access

### 3. Direct database access

Examples:

- Postgres
- MySQL
- Redis
- Cloud SQL

Reason for deferral:

- this is a different risk class from brokered outbound HTTP(S)
- future support would likely need dedicated adapters and more careful policy controls

## Explicitly Out Of Scope

These are not V1 features and should not shape the initial design.

### 1. Direct private git transport by agents

Examples:

- `git clone`
- `git fetch`
- `git pull`
- `git push`

Private repo transport will be handled manually outside the sandbox.

### 2. Tunnels and arbitrary transport-level reachability

Examples:

- GCP IAP tunnels
- SSH forwarding
- arbitrary TCP connectivity
- port forwarding to protected internal services

These are materially harder to scope and audit than brokered HTTP(S) requests.

### 3. Browser / E2E-specific support as a first-class target

Some browser or test workflows may work incidentally if they can use the same
HTTP(S) broker. But V1 should not introduce browser-specific interfaces or design
constraints.

## Design Constraints For V1

### 1. Shared VM, per-project policy

Because one VM may serve multiple projects, credential scope must be resolved per
project root.

The effective unit of authorization is:

```text
(project_root, capability_name)
```

### 2. Explicit reload only

Project credential manifests are loaded into the broker explicitly.

No automatic file watching or hot reload.

Expected control-plane shape:

- `dvm credentials reload [path]`
- `dvm credentials list`
- `dvm credentials show <name>`
- `dvm credentials status`

### 3. HTTP(S)-only request path

V1 should support only outbound `http` and `https` requests through a host-side broker.

No generic socket proxying.
No SSH-style transport in V1.
No DB connections in V1.

### 4. Manifest-driven policy

Each project defines allowed capabilities in a project manifest.

The manifest should define:

- capability name
- handler type
- provider reference
- allowed hosts
- allowed path prefixes
- allowed HTTP methods
- optional byte limits

The manifest must not contain raw secret material.

### 5. Selected writes are allowed

The design should not assume credentials are for read-only requests only.

Selected write actions are in scope when explicitly allowed by policy.

## Success Criteria

V1 is successful if it enables this workflow:

1. A project defines a small manifest of approved HTTP(S) capabilities.
2. The manifest is explicitly loaded into the shared VM's broker.
3. Tools inside the VM can make authenticated HTTP(S) requests for that project.
4. The guest never sees the raw credential.
5. Requests outside approved host/path/method policy fail loudly.

## Non-Goals For V1

- Solve every kind of credentialed workflow
- Support all third-party tools equally on day one
- Provide a universal secret transport layer
- Design around production-grade infrastructure access

V1 should be optimized for development ergonomics and a narrow, defensible security model.
