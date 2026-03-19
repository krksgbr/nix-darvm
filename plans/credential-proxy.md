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
VM lifecycle                            gvisor-tap-vsock (DHCP, DNS, frame I/O)
Config + secret resolution              Custom TCP handler (credential interception)
Sidecar supervision                ---> JSON control socket
Guest trust-store setup
CLI

   socketpair(AF_UNIX, SOCK_DGRAM)
   fd[0] -> VZFileHandleNetworkDeviceAttachment (guest NIC)
   fd[1] -> passed as stdin to dvm-netstack
```

The sidecar uses `gvisor-tap-vsock` as a library for the networking foundation
(DHCP, DNS, frame I/O via `tap.Switch`). Only the TCP handler is custom — it
routes port 80/443 to our credential interception proxy and passes everything
else through to the real destination.

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
- Placeholder generation (per-project unique placeholders)
- Sidecar process supervision (launch via stdin FD, health check, shutdown)
- Guest trust-store installation (via gRPC Exec, CA PEM from sidecar)
- Per-process placeholder env var injection (via gRPC `EnvVar` field)
- User-visible CLI (`dvm credentials reload`, `dvm status`)

**dvm-netstack owns:**
- gvisor-tap-vsock: DHCP server, DNS forwarding, frame I/O (`tap.Switch`)
- Ephemeral CA generation (Go `crypto/x509`, returned to host via control socket)
- TLS leaf cert issuance (cached per hostname)
- HTTP/HTTPS interception with placeholder substitution
- SNI peek for selective MITM (only credentialed hosts)
- TCP passthrough for non-intercepted traffic
- Connection lifecycle

### Sidecar Interface

**Startup:**
```
dvm-netstack --frame-fd 0 --control-sock /tmp/dvm-netstack-<pid>.sock
```

The socketpair FD is passed as **stdin** (fd 0) because Swift's `Process`/NSTask
uses `posix_spawn` which only inherits stdio FDs. Secrets are NEVER passed via
argv or env — only via the control socket after startup.

**Control channel (Unix domain socket, JSON messages):**

dvm-core -> sidecar:
- `load_config` — initial config (subnet, DNS, secrets). Sidecar generates CA and
  blocks the response until the stack is ready.
- `load(project_root, secrets[])` — add or replace one project's resolved rules
- `unload(project_root)` — remove one project's rules
- `status`
- `shutdown`

sidecar -> dvm-core:
- `ready` — with guest IP and `ca_cert_pem` (generated by sidecar)
- `status` — healthy, secret count
- `error`
- `ok`

### CA Certificate Lifecycle

The CA is generated **in Go** (not Swift) for reliability and is **stable for
the VM lifetime**:

1. dvm-core sends empty CA PEM fields in `load_config`
2. Sidecar generates ephemeral RSA 2048 CA via Go's `crypto/x509` (proven, no custom DER)
3. CA cert PEM returned in the `ready` response
4. dvm-core installs CA PEM in guest trust store (`security add-trusted-cert`)
5. dvm-core writes CA to `/etc/dvm-ca.pem` and sets `NODE_EXTRA_CA_CERTS`
6. Project reloads do not require CA rotation
7. Sidecar handles all leaf cert issuance internally (cached per hostname)

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

With project-scoped placeholders (next step #2), overlapping hosts are safe:
different projects get different placeholders that map to different real values.
The sidecar matches by placeholder, not by host alone.

For now (VM-global mode), overlapping exact hosts across projects are rejected
at load time to avoid ambiguity.

## File Layout (as built)

### Go: dvm-netstack sidecar (`host/netstack/`)

- `cmd/main.go` — entry point, wraps stdin FD as `net.Conn`, waits for config, starts stack
- `internal/stack/stack.go` — gvisor-tap-vsock integration (DHCP, DNS, frame I/O), custom TCP handler for credential interception
- `internal/proxy/http.go` — HTTP/HTTPS interception, SNI peek, placeholder substitution, inject rules, streaming support
- `internal/proxy/tls.go` — CA generation (`GenerateCA`), leaf cert issuance, PEM import (`NewCAPool`), cert caching
- `internal/control/control.go` — JSON control socket (load_config, load, unload, status, shutdown), per-project secret registry
- `go.mod` — depends on `gvisor-tap-vsock`, `gvisor.dev/gvisor`

### Swift: dvm-core changes (`host/Sources/`)

- `SecretConfig.swift` — TOML parsing, provider resolution (env/keychain/command), placeholder generation, host overlap detection
- `NetstackSupervisor.swift` — sidecar lifecycle (socketpair, stdin FD passing, control socket, health monitoring, shutdown)
- `EphemeralCA.swift` — **dead code**, CA now generated in Go. Should be deleted.
- `VMConfigurator.swift` — conditional `VZFileHandleNetworkDeviceAttachment` when `netstackFD` provided
- `Config.swift` — `credentialManifestPaths(additionalDirs:)` discovers `.dvm/credentials.toml`
- `AgentClient.swift` — `exec(env:)` and `execInteractive(env:)` with `EnvVar` support
- `Main.swift` — full lifecycle: discover manifests, resolve secrets, launch sidecar, configure, install CA, monitor

### Proto

- `proto/agent.proto` — `EnvVar` message, `environment` field on `Command`
- `host/Sources/Protos/agent.proto` — synced copy for Swift SPM plugin
- `guest/agent/gen/` — regenerated Go code

## Technical Notes

- **gvisor-tap-vsock as a library:** DHCP, DNS, and frame I/O use `gvisor-tap-vsock` (`tap.Switch`, `dhcp.New`, `dns.New`). We don't reimplement networking — only the TCP handler is custom. The socketpair connects via `netSwitch.Accept(ctx, conn, types.VfkitProtocol)`.
- **FD passing via stdin:** Swift's `Process`/NSTask uses `posix_spawn` which only inherits stdio FDs. The socketpair endpoint is passed as stdin (fd 0). The Go sidecar wraps it with `net.FileConn(os.Stdin)` immediately at startup to prevent GC finalization.
- **Placeholder model (from matchlock):** Proxy does string replacement across all request headers + URL query params. Skips body intentionally (prevents secrets leaking via server-side logging of request bodies). Also synthesizes inject-rule headers (bearer/basic/custom) when the guest didn't send a placeholder.
- **SNI peek for selective MITM:** HTTPS connections are peeked for the TLS ClientHello SNI before deciding MITM vs passthrough. Non-credentialed hosts get raw TCP passthrough without TLS termination.
- **VZ socketpair:** `socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds)`. DGRAM = one Ethernet frame per read/write. Uses `VfkitProtocol` (bare L2, not QEMU's 4-byte length prefix).
- **DHCP:** gvisor-tap-vsock's DHCP server on 192.168.64.0/24 subnet. Guest gets next available IP from pool (typically .3), gateway at .1.
- **CA generated in Go:** `crypto/x509.CreateCertificate` — reliable, no custom DER. CA PEM returned to Swift via the control socket `ready` response. Installed in guest System Keychain + `/etc/dvm-ca.pem` for `NODE_EXTRA_CA_CERTS`.
- **Keychain provider caveat:** `security find-generic-password -w` may block on a Keychain authorization prompt in non-interactive contexts.
- **Backward compatible:** No secrets configured = NAT attachment used, no sidecar launched, zero behavior change.
- **Failure mode:** If sidecar dies, dvm-core marks credentials unhealthy and fails loudly. VM networking fails closed; there is no silent bypass around the sidecar. Clean shutdown sets `_shuttingDown` flag to avoid false crash alerts.
- **Route table:** Must use `header.IPv4EmptySubnet` as the default route destination, not `tcpip.Subnet{}` (zero-value breaks locally-generated response routing).
- **No custom UDP forwarder:** DNS and DHCP use their own bound endpoints from gvisor-tap-vsock. Installing a generic UDP forwarder conflicts with these and steals their traffic.

## Future Work (not v1)

- **Network allowlisting beyond MITM scope:** V1 only constrains which hosts are intercepted for credential injection. A future version could deny or filter all egress, not just credentialed traffic.
- **LLM usage tracking:** Detect requests to known AI API domains, extract model/token counts (AgentKernel does this).
- **Audit hooks:** Log all proxied requests with host, secret-injected flag.
- **Connection-preserving reload:** V1 already supports control-socket rule updates; a future version could preserve more in-flight connection state across changes.
- **Migrate config to nix:** Part of the broader config.toml -> nix migration (nix-darvm-xuus).

## Current Status

HTTP credential injection works end-to-end. Verified: guest sends placeholder
in header → sidecar replaces with real secret → upstream receives real value.
gvisor-tap-vsock provides DHCP, DNS, and frame I/O. HTTPS passthrough works
for non-credentialed hosts.

## Next Steps

### 1. Minimize base image + SSH bootstrap

See [plans/minimal-base-image.md](minimal-base-image.md). Separate plan with
open questions being worked through.

### 2. Wire env vars into dvm exec/shell

The proto has the `EnvVar` field and the guest agent applies them. But the
`Exec` and `SSH` commands in Main.swift don't pass credential env vars yet.

- Determine project context from cwd (find nearest `.dvm/credentials.toml`)
- Pass that project's placeholders via the `env:` parameter on `agentClient.exec()`
- Also wire into `execInteractive()` for `dvm shell`

### 3. Project-scoped secrets via per-project placeholders

Each project gets unique placeholders. The placeholder itself carries project
identity — the sidecar doesn't need to know which process sent the request.

Model:
- Project A: `ANTHROPIC_API_KEY=SANDBOX_SECRET_aaa` → maps to A's real key
- Project B: `ANTHROPIC_API_KEY=SANDBOX_SECRET_bbb` → maps to B's real key
- `dvm exec` in project A's directory only injects `SANDBOX_SECRET_aaa`
- Sidecar matches placeholder → real value, host allowlist is a guardrail

This means:
- Different projects can have credentials for the same host
- A process in project A can't use project B's credentials (it doesn't have the placeholder)
- No sidecar changes needed — just unique placeholders per project on the host side

### 4. Test HTTPS MITM with real credentialed host

CA is generated and installed. The MITM code path exists. Needs testing with
a real HTTPS API (e.g., `curl https://api.anthropic.com/...` with a real key).

### 5. Clean up dead code

- Delete `EphemeralCA.swift` (CA now generated in Go)
- Remove stale `handleUDPPacket` and related dead code from stack.go
- Clean up unused imports

### 6. Fix HTTP-to-raw-IP passthrough

`curl http://93.184.216.34` returns 502 (Bad Gateway). The TCP passthrough
for non-intercepted hosts on port 80 uses the raw IP which may fail DNS-based
routing. Low priority — DNS-based requests work fine.

### 7. Central config option

Support secrets in `~/.config/dvm/config.toml` in addition to per-project
`.dvm/credentials.toml`, so you don't need a manifest in every repo.

### 8. `dvm credentials reload` CLI command

Re-resolve secrets and push to sidecar without restarting the VM.
The control socket `load`/`unload` protocol already supports this.
