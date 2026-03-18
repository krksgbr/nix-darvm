# Transparent Credential Proxy for DVM

## Problem

AI agents in the DVM guest need API keys (Anthropic, OpenAI, GitHub, etc.) but giving them real secrets is a security risk. We want transparent credential injection: the guest sees only placeholder values, and a host-side proxy swaps them for real secrets in HTTP(S) request headers before they leave the machine. The guest never has the real credentials.

**Design principle:** Security should be convenient, not friction. The guest environment should feel the same as the host — same env vars, same curl commands, same code.

## Prior Art

Surveyed three existing implementations:

| | Matchlock | Cleanroom | AgentKernel |
|---|---|---|---|
| **Interception** | Transparent (gVisor netstack) | Gateway + URL rewrite | Explicit proxy (HTTP_PROXY) |
| **MITM TLS** | Yes | No (HTTP to gateway) | Yes |
| **Placeholder model** | Yes | No (gateway injects directly) | Yes |
| **Language** | Go | Go | Rust |
| **Allowlisting** | Yes | Yes (iptables) | Optional |

All three converge on the same core: placeholder tokens + host-side substitution. The variation is how traffic reaches the proxy.

## Chosen Approach

**Transparent interception via gVisor netstack (Go sidecar) + VZFileHandleNetworkDeviceAttachment.**

### Why transparent interception (not explicit proxy)

We also considered an explicit proxy (HTTP_PROXY/HTTPS_PROXY env vars + BASE_URL overrides for known LLM providers). That approach is simpler but has fundamental limitations:

- **HTTPS gap:** A forward proxy using CONNECT tunneling can't see or modify HTTP headers inside the TLS tunnel. Without MITM, credential injection doesn't work for HTTPS — which is everything that matters (Anthropic, OpenAI, GitHub APIs).
- **Requires per-tool integration:** Each LLM provider needs a provider-compatible local endpoint (BASE_URL override). Works for SDKs that read BASE_URL, fails for raw `curl`, scripts, or unknown tools. Creates an ongoing maintenance tail.
- **Breaks environment parity:** Host uses real URLs; guest uses overridden URLs. Code that works on the host needs modification in the guest. This directly contradicts the "same env var everywhere" goal.

Transparent interception avoids all of this: arbitrary HTTPS clients work naturally with placeholder env vars.

### Why Go sidecar (not lwIP-in-Swift)

We also considered lwIP (C userspace TCP stack) integrated directly into dvm-core (Swift). That approach was attractive for keeping everything in a single process, but:

- **Uncharted territory:** No reference implementations exist for VZ framework + lwIP. We'd be pioneering the integration.
- **C memory model + Swift bridging:** pbuf lifecycle management in C callbacks bridged to Swift via `Unmanaged<T>` is error-prone, especially for security-sensitive code handling real credentials.
- **"Single process" is not obviously simpler:** For credential handling, isolation is a feature. A sidecar that can crash/restart independently is genuinely better than embedding the risk in the main binary.
- **Proven references:** matchlock, gvisor-tap-vsock, Podman, and Lima all use gVisor netstack on macOS with the exact same VZ pattern. matchlock's stack_darwin.go (~400 lines) + http.go + tls.go (~450 lines) is a working reference.
- **Testable independently:** The sidecar can be fed raw pcap frames and tested without a VM running.

### Key Decisions

- Secret values come from **host-side provider resolution**
- V1 supports **three explicit provider kinds**:
  - `env`
  - `keychain`
  - `command`
- **Per-project config** with host-side resolution (declarations in repo, no secrets in the file)
- **MITM scope is deny-by-default for credentialed hosts:** only hosts declared in a project's credential config are intercepted for HTTP parsing / HTTPS MITM. Everything else is tunneled or passed through without MITM.
- **Provider validation happens eagerly at reload:** env refs, keychain refs, and command providers must validate successfully before new config becomes active
- Backward compatible: no secrets configured = NAT networking (unchanged behavior)

## Architecture

```
dvm-core (Swift)                        dvm-netstack (Go sidecar)
================                        =========================
VM lifecycle                            gVisor netstack
Config + secret resolution         <--- inherited frame FD
Sidecar supervision                ---> JSON control socket
Guest trust-store setup
CLI

   socketpair(AF_UNIX, SOCK_DGRAM)
   fd[0] -> VZFileHandleNetworkDeviceAttachment (guest NIC)
   fd[1] -> inherited by dvm-netstack (raw Ethernet frames)
```

### Data Flow

```
Guest app: curl -H "x-api-key: $ANTHROPIC_API_KEY" https://api.anthropic.com/...
  (ANTHROPIC_API_KEY = "SANDBOX_SECRET_7a3f9b2e...")

Guest NIC (Virtio)
  -> socketpair fd[0] (SOCK_DGRAM, raw Ethernet frames)
     -> fd[1] in dvm-netstack
        -> gVisor netstack processes TCP/IP
           -> Port 80:  HTTP proxy — parse request, replace placeholders, forward upstream
           -> Port 443: TLS MITM — terminate with leaf cert, parse HTTP, replace, forward
           -> Other:    Passthrough — bidirectional relay to host socket
        -> Response flows back through netstack -> socketpair -> guest NIC
```

### Ownership Boundary

**dvm-core owns:**
- Per-project manifest discovery (`.dvm/credentials.toml`)
- Secret provider resolution (keychain, env, command)
- Placeholder generation
- VM-scoped CA cert generation (stable for VM lifetime)
- Sidecar process supervision (launch, health check, restart, shutdown)
- Guest trust-store installation (via gRPC Exec)
- Per-process/session placeholder env var injection
- User-visible CLI (`dvm credentials reload`, `dvm status`)

**dvm-netstack owns:**
- Raw frame I/O from socketpair FD
- gVisor TCP/IP stack
- DHCP server + DNS forwarding
- HTTP/HTTPS interception
- TLS leaf cert issuance (using CA from dvm-core)
- Placeholder -> real secret substitution in headers/query params
- TCP passthrough for non-HTTP traffic
- Tunneling / passthrough for traffic outside declared credential host scope
- Connection lifecycle

### Sidecar Interface

**Startup:**
```
dvm-netstack --frame-fd 3 --control-sock /tmp/dvm-netstack-<id>.sock
```

Only the frame FD and control socket path are passed at launch. Secrets are NEVER passed via argv or env — only via the control socket after startup.

**Control channel (Unix domain socket, JSON messages):**

dvm-core -> sidecar:
- `load(project_root, secrets[])` — add or replace one project's resolved rules
- `unload(project_root)` — remove one project's rules
- `status`
- `shutdown`

sidecar -> dvm-core:
- `ready` — with guest IP
- `status` — healthy, active connections, loaded secret count
- `error`
- `ok`

### CA Certificate Lifecycle

The CA is **stable for the VM lifetime** to avoid reinstalling trust store on reload:

1. dvm-core generates ephemeral RSA 2048 CA once at VM start
2. CA cert+key passed to sidecar at startup, then reused for the VM lifetime
3. dvm-core installs CA PEM in guest trust store (`security add-trusted-cert`)
4. Project reloads do not require CA rotation or guest trust-store changes
5. Sidecar handles all leaf cert issuance internally (cached per hostname)

### Reload Model (v1: control-socket update)

1. `dvm credentials reload /path/to/project`
2. dvm-core re-reads `.dvm/credentials.toml`, re-resolves secrets
3. dvm-core validates providers eagerly
4. dvm-core sends `load(project_root, secrets[])` over the control socket
5. sidecar applies the updated rules atomically and responds `ok`

Sidecar restart is reserved for:

- sidecar binary upgrades
- CA rotation
- sidecar crashes

Normal project reload should not require a sidecar restart.

## Configuration

**Per-project:** `.dvm/credentials.toml` lives in the repo. Contains only declarations and provider references — no secret values. The host reads this from the mounted project directory.

```toml
version = 1

[[secrets]]
name = "anthropic"
hosts = ["api.anthropic.com"]
inject = { type = "header", name = "x-api-key" }
provider = { type = "command", argv = ["op", "read", "op://Dev/Anthropic/api-key"] }

[[secrets]]
name = "github"
hosts = ["api.github.com", "uploads.github.com"]
inject = "bearer"
provider = { type = "keychain", service = "github.com", account = "work-bot" }

[[secrets]]
name = "openai"
hosts = ["api.openai.com"]
inject = "bearer"
provider = { type = "env", name = "OPENAI_API_KEY" }
```

The host resolves each provider at load time. Real values stored in memory only.
A placeholder (`SANDBOX_SECRET_<32 hex chars>`) is generated per secret.

### Placeholder env var scope

Credential-related env vars are never written into the guest's global
environment at activation time.

V1 rule:

- placeholders are injected per launched process/session based on project context
- wrappers such as `dvm run-credentialed --project . -- ...` set the relevant
  placeholder env vars for that process tree only
- the guest's global environment contains no credential placeholders

This is the only correct scope for a shared multi-project VM.

### V1 schema rules

- `version` is required and must be `1`
- `[[secrets]]` is the top-level rule shape
- `name` is a human-facing identifier
- `hosts` is required
- `inject` is required
- `provider` is required

Supported `inject` forms in V1:

- `"bearer"`
- `"basic"`
- `{ type = "header", name = "..." }`

Supported `provider` forms in V1:

- `{ type = "env", name = "..." }`
- `{ type = "keychain", service = "...", account = "..." }`
- `{ type = "command", argv = ["..."] }`

### V1 host matching rule

Use exact host matches only in V1.

No wildcard hosts.

Examples:

- allowed: `api.github.com`
- allowed: `uploads.github.com`
- not allowed in V1: `*.github.com`

This keeps overlap checks and interception scope unambiguous.

### Reload-time validation

`dvm credentials reload /path/to/project` validates provider references eagerly before activating new config:

- **env**: referenced variable must be present and non-empty
- **keychain**: referenced item must exist and be readable
- **command**: executable must exist; provider should be dry-run if the command contract allows it

Provider output rule:

- strip trailing whitespace and newlines from resolved secret values before storing them
- reject empty values after trimming

If validation fails:

- reload fails loudly with the provider name and exact error
- the previous config remains active
- the sidecar rule set is not modified

This follows the rule: fail loudly, never silently degrade.

### Overlapping host rule

If two loaded projects declare overlapping host scopes, reload fails for the
second project with an explicit conflict error.

V1 rule:

- overlapping exact hosts across projects are rejected

This avoids silent wrong-credential injection.

## Files to Create

### Go: dvm-netstack sidecar

- `host/netstack/cmd/main.go` — entry point (--frame-fd, --control-sock)
- `host/netstack/internal/stack/stack.go` (~400 lines) — gVisor netstack init, frame I/O, TCP/UDP forwarders. Reference: matchlock's stack_darwin.go
- `host/netstack/internal/proxy/http.go` (~300 lines) — HTTP/HTTPS interception, placeholder substitution, upstream forwarding. Reference: matchlock's http.go
- `host/netstack/internal/proxy/tls.go` (~100 lines) — leaf cert issuance from provided CA, cert caching
- `host/netstack/internal/control/control.go` (~100 lines) — JSON control socket handler
- `host/netstack/internal/dhcp/dhcp.go` — DHCP server for guest (gVisor or minimal implementation)
- `host/netstack/internal/dns/dns.go` — DNS forwarder to host resolver

### Swift: dvm-core changes

- `host/Sources/SecretConfig.swift` (~80 lines) — secret configuration types, placeholder generation, host matching
- `host/Sources/NetstackSupervisor.swift` (~150 lines) — sidecar process management (launch, control socket, health, restart)

## Files to Modify

- `host/Sources/VMConfigurator.swift` — when secrets configured, use VZFileHandleNetworkDeviceAttachment; create socketpair; return NetworkStack handle
- `host/Sources/Config.swift` — add secrets loading from per-project `.dvm/credentials.toml`
- `host/Sources/Main.swift` — resolve secrets, generate CA, launch sidecar, install CA in guest
- `host/Sources/AgentClient.swift` / process-launch path — add per-process placeholder env injection based on project context

## Implementation Phases

### Phase 1: Sidecar with basic networking

Build dvm-netstack with gVisor netstack. DHCP server + DNS forwarding + TCP passthrough. dvm-core creates socketpair, launches sidecar, supervises process.

**Verify:** Guest boots, gets IP via DHCP, `curl http://example.com` works, `nslookup` resolves.

### Phase 2: HTTP credential injection

Add HTTP parser and proxy for port 80. Wire secret config, provider resolution, placeholder generation. Control socket protocol.

**Verify:** Guest `curl http://httpbin.org/headers -H "x-api-key: SANDBOX_SECRET_xxx"` returns response showing the real key.

### Phase 3: HTTPS MITM

Add CA generation in dvm-core, leaf cert issuance in sidecar. TLS termination + re-encryption. Install CA cert in guest during activation.

**Verify:** Guest `curl https://api.anthropic.com/v1/messages -H "x-api-key: $ANTHROPIC_API_KEY"` succeeds with real key injected.

### Phase 4: Real-API checkpoint

Before building more layers on top, validate HTTPS MITM against one real API
end-to-end.

**Verify:** A real provider request succeeds through MITM with a host-resolved
credential and no raw secret in the guest.

### Phase 5: Per-process env injection + end-to-end

Add wrapper-driven placeholder env injection per launched process/session.
Per-project config loading. Reload support.

**Verify:** End-to-end: configure `.dvm/credentials.toml`, start VM, agent uses `$ANTHROPIC_API_KEY` naturally, API calls succeed.

## Technical Notes

- **Placeholder model (from matchlock):** Proxy does string replacement across all request headers + URL query params. Skips body intentionally (prevents secrets leaking via server-side logging of request bodies).
- **Interception scope:** HTTP and HTTPS follow the same rule:
  - destination host matches a declared `secrets[].hosts`: intercept, inspect, inject
  - all other traffic: passthrough / tunnel only, no MITM, no inspection
- **VZ socketpair:** `socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds)`. DGRAM means each read/write is exactly one Ethernet frame — no framing protocol needed.
- **DHCP:** 192.168.64.0/24 subnet, guest gets .2, gateway .1. DNS points to gateway (our forwarder).
- **CA cert installation:** Via gRPC Exec: `security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain`. For Node.js: set `NODE_EXTRA_CA_CERTS` env var.
- **Guest OS trust path:** Verify the guest OS before implementation. The trust-store installation command must match the actual guest. If the guest is macOS, `security add-trusted-cert` is appropriate. If the guest is not macOS, use the OS-native trust anchor mechanism instead.
- **Keychain provider caveat:** `security find-generic-password -w` may block on a Keychain authorization prompt. This must be tested early, especially when `dvm-core` runs under launchd or another non-interactive context. Pre-authorizing `dvm-core` for required items may be necessary.
- **Backward compatible:** No secrets configured = NAT attachment used, no sidecar launched, zero behavior change.
- **Control socket:** JSON request/response over Unix socket. Synchronous apply for V1.
- **Failure mode:** If sidecar dies, dvm-core marks credentials unhealthy and fails loudly. VM networking fails closed; there is no silent bypass around the sidecar.
- **Guest env scope:** Placeholder env vars exist only in wrapper-launched process trees, never globally in the guest.

## Future Work (not v1)

- **Network allowlisting beyond MITM scope:** V1 only constrains which hosts are intercepted for credential injection. A future version could deny or filter all egress, not just credentialed traffic.
- **LLM usage tracking:** Detect requests to known AI API domains, extract model/token counts (AgentKernel does this).
- **Audit hooks:** Log all proxied requests with host, secret-injected flag.
- **Connection-preserving reload:** V1 already supports control-socket rule updates; a future version could preserve more in-flight connection state across changes.
- **Migrate config to nix:** Part of the broader config.toml -> nix migration (nix-darvm-xuus).

## Concrete Task Breakdown

### Task 1: Confirm guest trust-store path

- verify the actual guest OS and trust-store mechanism
- document the exact command sequence for installing the VM CA
- add a fingerprint check so trust installation is idempotent

### Task 2: Finalize manifest parsing and validation

- implement `version = 1`
- implement flat `[[secrets]]` parsing
- implement explicit `inject` parsing
- implement explicit `env`, `keychain`, and `command` providers
- enforce exact-host-only matching
- trim provider outputs and reject empty results

### Task 3: Validate provider behavior early

- test env provider failure modes
- test command provider dry-run behavior
- test keychain lookup in interactive and launchd-like contexts
- decide how to surface keychain authorization failures clearly

### Task 4: Define and implement control socket schema

- request/response JSON format
- `status`, `load`, `unload`, `shutdown`
- synchronous apply semantics
- explicit error codes for host conflicts and validation failures

### Task 5: Build sidecar skeleton and supervision

- Go sidecar entrypoint
- frame FD ownership
- JSON control socket server
- `dvm-core` process launch, health checks, shutdown, and crash detection

### Task 6: Bring up transport basics

- `VZFileHandleNetworkDeviceAttachment`
- socketpair frame plumbing
- gVisor netstack
- DHCP and DNS forwarding
- plain passthrough networking

### Task 7: Implement HTTP interception

- parse HTTP requests
- exact-host matching
- placeholder substitution in headers/query params
- upstream forwarding

### Task 8: Implement HTTPS MITM

- stable VM-lifetime CA
- leaf certificate issuance in sidecar
- guest trust-store installation
- HTTPS interception for declared hosts only

### Task 9: Prove the real-API path

- run one real provider request end-to-end
- verify injected credential works
- verify raw secret never appears in guest env or request construction

### Task 10: Add per-process placeholder env injection

- wrapper-driven env injection for launched tools/processes
- no global guest env mutation
- tie injection to project context

### Task 11: Multi-project load/unload behavior

- support loading multiple project rule sets
- reject overlapping exact hosts
- verify unload removes rules cleanly

### Task 12: End-to-end verification

- one project / one secret / one real API
- multiple projects with non-overlapping hosts
- overlapping-host rejection
- sidecar crash behavior is fail-closed
