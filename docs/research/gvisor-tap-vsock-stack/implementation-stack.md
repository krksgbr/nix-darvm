# Implementation Stack: Credential Proxy on gvisor-tap-vsock

A complete specification of every component needed to build the transparent credential-injecting MITM proxy, and what fills each gap.

---

## Architecture Overview

```
Guest VM (macOS)
    |
    | raw Ethernet frames over SOCK_DGRAM
    | (VZFileHandleNetworkDeviceAttachment)
    |
    v
┌─────────────────────────────────────────────────────────────┐
│  Host-side sidecar (single Go process)                      │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  gvisor-tap-vsock (embedded as Go library)            │  │
│  │                                                       │  │
│  │  ┌─────────┐  ┌──────┐  ┌──────┐  ┌──────────────┐  │  │
│  │  │ L2      │  │ DHCP │  │ DNS  │  │ TCP forwarder│  │  │
│  │  │ switch  │  │      │  │      │  │ (per-conn    │  │  │
│  │  │         │  │      │  │      │  │  callback)   │  │  │
│  │  └─────────┘  └──────┘  └──────┘  └──────┬───────┘  │  │
│  │       gVisor netstack (userspace TCP/IP)  │          │  │
│  └───────────────────────────────────────────┼──────────┘  │
│                                              │              │
│                               ┌──────────────┘              │
│                               │                             │
│                     ┌─────────v──────────┐                  │
│                     │ port 443 + SNI in  │   NO             │
│                     │ intercept list?    ├──────> passthrough│
│                     └─────────┬──────────┘       (blind TCP │
│                               │ YES               proxy)    │
│                               v                             │
│                     ┌────────────────────┐                  │
│                     │ TLS termination    │                  │
│                     │ (dynamic cert)     │                  │
│                     └────────┬───────────┘                  │
│                              │                              │
│                     ┌────────v───────────┐                  │
│                     │ net/http.Server    │                  │
│                     │ (HTTP/1.1 + HTTP/2)│                  │
│                     └────────┬───────────┘                  │
│                              │                              │
│                     ┌────────v───────────┐                  │
│                     │ httputil.Reverse   │                  │
│                     │ Proxy              │                  │
│                     │ - swap token       │                  │
│                     │ - stream SSE       │                  │
│                     └────────┬───────────┘                  │
│                              │                              │
│                     ┌────────v───────────┐                  │
│                     │ TLS to real        │                  │
│                     │ upstream           │                  │
│                     └────────────────────┘                  │
└─────────────────────────────────────────────────────────────┘
```

---

## Complete Component Table

| # | Component | What it does | Provided by | Custom code |
|---|-----------|-------------|-------------|-------------|
| | **Network layer** | | | |
| 1 | VM NIC attachment | Connects guest virtual NIC to host via socketpair | `VZFileHandleNetworkDeviceAttachment` (Apple VZ framework) | 0 lines |
| 2 | Ethernet frame I/O | Reads/writes bare L2 frames over SOCK_DGRAM | gvisor-tap-vsock `VfkitProtocol` | 0 lines |
| 3 | Userspace TCP/IP stack | Parses Ethernet → IP → TCP/UDP, reassembles TCP streams | gVisor netstack (via gvisor-tap-vsock) | 0 lines |
| 4 | L2 switch | Ethernet switching, MAC learning, ARP | gvisor-tap-vsock `pkg/tap/switch.go` | 0 lines |
| 5 | DHCP server | Assigns IP, gateway, DNS to guest | gvisor-tap-vsock `pkg/services/dhcp` | 0 lines |
| 6 | DNS server | Resolves queries, configurable zones, HTTP API | gvisor-tap-vsock `pkg/services/dns` | 0 lines |
| | **Interception layer** | | | |
| 7 | TCP forwarder with intercept hook | Routes each TCP connection: intercept or passthrough | gvisor-tap-vsock `tcp.NewForwarder` callback (modified) | ~40 lines |
| 8 | Guest-side net.Conn | Go `net.Conn` from the guest's TCP connection | `gonet.NewTCPConn` (gVisor adapter) | 0 lines |
| 9 | SNI extraction | Peeks TLS ClientHello, extracts server name without consuming bytes | `inetaf/tcpproxy` (already vendored in gvisor-tap-vsock) | ~15 lines |
| 10 | Intercept decision | Checks SNI against allowlist of target API hosts | Custom (simple map lookup) | ~10 lines |
| 11 | Non-intercepted passthrough | Blind TCP proxy for connections we don't touch | gvisor-tap-vsock `tcpproxy.DialProxy` (existing behavior) | 0 lines |
| | **TLS MITM layer** | | | |
| 12 | TLS termination (client-facing) | Accepts TLS from guest, presents dynamically generated cert | `crypto/tls.Server` with `GetCertificate` callback | ~15 lines |
| 13 | ALPN negotiation | Negotiates HTTP/2 or HTTP/1.1 with the guest client | `crypto/tls` (automatic when `NextProtos: ["h2", "http/1.1"]` is set) | 0 lines |
| 14 | Dynamic cert generation | Generates ECDSA-P256 leaf cert for the target hostname, signed by our CA | `crypto/x509.CreateCertificate` + `crypto/ecdsa` | ~30 lines |
| 15 | Certificate cache | Caches generated certs by hostname, avoids re-generation | Custom (`sync.RWMutex` + `map[string]*tls.Certificate`) | ~25 lines |
| 16 | CA key pair | ECDSA-P256 CA certificate + private key (generated at startup or loaded) | `crypto/ecdsa.GenerateKey` + `crypto/x509.CreateCertificate` | ~20 lines |
| | **HTTP layer** | | | |
| 17 | HTTP/1.1 serving | Parses HTTP/1.1 requests from the terminated TLS connection | `net/http.Server` | 0 lines |
| 18 | HTTP/2 serving | Parses HTTP/2 frames, handles multiplexed streams | `net/http.Server` + `golang.org/x/net/http2.ConfigureServer` (automatic via ALPN) | ~5 lines |
| 19 | One-shot listener | Wraps a single `net.Conn` as a `net.Listener` for `http.Server.Serve()` | Custom (established Go pattern) | ~15 lines |
| | **Credential injection** | | | |
| 20 | Reverse proxy | Forwards requests to real upstream, streams responses back | `net/http/httputil.ReverseProxy` | ~10 lines |
| 21 | Token replacement | Swaps placeholder token in Authorization header with real API key | Custom (`Director` func on ReverseProxy) | ~20 lines |
| 22 | Credential store | Provides real API key for a given target host | Custom (reads from host env vars, Keychain, or config) | ~30 lines |
| | **Response handling** | | | |
| 23 | SSE streaming | Flushes `text/event-stream` responses immediately, no buffering | `httputil.ReverseProxy` (automatic — detects content type) | 0 lines |
| 24 | HTTP/2 response multiplexing | Handles multiplexed HTTP/2 response streams | `net/http.Server` + `httputil.ReverseProxy` (automatic) | 0 lines |
| 25 | Hop-by-hop header removal | Strips Connection, Keep-Alive, etc. per RFC 2616 | `httputil.ReverseProxy` (automatic) | 0 lines |
| 26 | Connection pooling to upstream | Reuses TLS connections to frequently-called API hosts | `net/http.Transport` (used internally by ReverseProxy) | 0 lines |
| 27 | TLS to upstream | Establishes TLS connection to real API server | `net/http.Transport` (automatic) | 0 lines |
| | **Guest trust** | | | |
| 28 | CA cert in guest trust store | Guest macOS trusts our CA for TLS verification | Baked into guest image via nix-darwin activation script | Config only |
| 29 | Supplementary CA env vars | Catches tools that ignore system trust store | `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS` set in guest env | Config only |

---

## What's Custom vs. What's Off-the-Shelf

### Off-the-shelf: 27 of 29 capabilities handled by existing code

```
gvisor-tap-vsock .... Ethernet I/O, TCP/IP stack, L2 switch, DHCP, DNS,
                      TCP forwarder framework, passthrough proxy,
                      SNI peeking (vendored inetaf/tcpproxy)

Go stdlib ........... TLS termination, ALPN negotiation, cert generation,
                      ECDSA keys, HTTP/1.1 server, reverse proxy,
                      SSE streaming, hop-by-hop headers, connection pooling,
                      upstream TLS

golang.org/x/net .... HTTP/2 server (automatic via ConfigureServer)
```

### Custom: ~200 lines across 10 small pieces

```
TCP forwarder hook ......... 40 lines   intercept decision in the callback
SNI peek + route ........... 25 lines   peek ClientHello, check allowlist
TLS setup .................. 15 lines   create tls.Server with config
Cert generation ............ 30 lines   x509.CreateCertificate wrapper
Cert cache ................. 25 lines   map + mutex + GetCertificate
One-shot listener .......... 15 lines   net.Conn → net.Listener adapter
HTTP/2 setup ............... 5  lines   http2.ConfigureServer call
ReverseProxy setup ......... 10 lines   create proxy, set Director
Token replacement .......... 20 lines   Director func: swap Authorization header
Credential store ........... 30 lines   load real keys from host config
                               ───
                          ~215 lines
```

---

## Dependency Chain

Zero external dependencies beyond what gvisor-tap-vsock already vendors:

| Dependency | Source | Already vendored? |
|-----------|--------|-------------------|
| `gvisor.dev/gvisor/pkg/tcpip` | gVisor netstack | Yes (gvisor-tap-vsock) |
| `gvisor.dev/gvisor/pkg/tcpip/adapters/gonet` | net.Conn adapter | Yes (gvisor-tap-vsock) |
| `github.com/inetaf/tcpproxy` | SNI peeking, conn wrapping | Yes (gvisor-tap-vsock) |
| `crypto/tls` | TLS termination | Go stdlib |
| `crypto/x509` | Cert generation | Go stdlib |
| `crypto/ecdsa`, `crypto/elliptic` | Key generation | Go stdlib |
| `net/http` | HTTP server, ReverseProxy | Go stdlib |
| `net/http/httputil` | ReverseProxy | Go stdlib |
| `golang.org/x/net/http2` | HTTP/2 server support | Go extended stdlib |

---

## gvisor-tap-vsock Internals

An implementer needs to understand these abstractions to wire up the credential proxy.

### Key Types

**`VirtualNetwork`** (`pkg/virtualnetwork/virtualnetwork.go`) — the top-level object. Creates the gVisor stack, the virtual switch, and wires up all services (DHCP, DNS, forwarders). Exposes `Dial()`, `Listen()`, and `DialContextTCP()` that operate within the virtual network namespace. This is the main integration point.

**`Switch`** (`pkg/tap/switch.go`) — Ethernet-level L2 switch with a CAM table. Receives raw frames from VM connections, learns MAC addresses, delivers packets to the gVisor stack via the `LinkEndpoint`.

**`LinkEndpoint`** (`pkg/tap/link.go`) — bridges L2 switch and L3+ gVisor TCP/IP stack. Handles Ethernet framing.

**TCP Forwarder** (`pkg/services/forwarder/tcp.go`) — registered as the transport protocol handler on the gVisor stack. For each TCP connection from the VM, it applies NAT, dials the real destination, and proxies bytes. This is where we insert the intercept hook.

### Embedding as a Go Library (Lima Pattern)

Lima embeds gvisor-tap-vsock as a library rather than running `gvproxy` as a subprocess:

1. `socketpair(AF_UNIX, SOCK_DGRAM)` — creates two connected file descriptors
2. One end passed to `VZFileHandleNetworkDeviceAttachment` (VM's NIC)
3. Other end passed to `VirtualNetwork.AcceptVfkit()` (gvisor-tap-vsock)
4. `VirtualNetwork` starts the gVisor stack, DHCP, DNS, and the TCP forwarder in-process

This is the recommended pattern for DVM. Single process, no IPC, direct access to the TCP forwarder callback for credential injection.

### DNS Zone Override API

gvisor-tap-vsock's DNS server supports dynamic zone management via HTTP API:

- `POST /services/dns/add` — add a DNS zone (e.g., `api.openai.com → sidecar IP`)
- `GET /services/dns/all` — list all zones
- Static zones can also be configured at startup via `Configuration.DNS`

This can be used for DNS-based interception as a complement to SNI-based interception: override DNS for target hosts so they resolve to the sidecar, then the sidecar receives the connection directly on its own IP.

### Default Network Layout

```
192.168.127.0/24  (virtual subnet)
192.168.127.1     (gateway — gvisor-tap-vsock sidecar)
192.168.127.2     (first VM, DHCP static lease)
192.168.127.254   (host alias, NAT'd to 127.0.0.1)
```

DNS zones: `*.containers.internal.` and `*.docker.internal.` resolve `gateway` and `host` names.

---

## Credential Injection Config Design

Reference: [Envoy Gateway's Credential Injector filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/credential_injector_filter), which solves the same problem (injecting API credentials into proxied requests) in a production setting.

### Useful patterns from Envoy's design

| Config option | What it does | Relevance to DVM |
|--------------|-------------|------------------|
| `overwrite` | Whether to replace an existing Authorization header | Useful — agent might send a phantom token or a real token; controls whether we always replace |
| `allow_request_without_credential` | Pass through requests if no credential is available for this host | Useful — fail-open vs fail-closed per host |
| Per-host credential source | Different credential type per upstream (Bearer, Basic, API key header) | Needed — OpenAI uses `Authorization: Bearer`, Anthropic uses `x-api-key`, GitHub uses `Authorization: token` |
| Metrics | Counters for injection success/failure per host | Useful for debugging — "is the proxy actually injecting?" |

### Suggested config structure for DVM

```yaml
credentials:
  - host: api.openai.com
    header: Authorization
    value_prefix: "Bearer "
    source: env:OPENAI_API_KEY      # read from host env var
  - host: api.anthropic.com
    header: x-api-key
    value_prefix: ""
    source: env:ANTHROPIC_API_KEY
  - host: api.github.com
    header: Authorization
    value_prefix: "token "
    source: keychain:github-token    # read from macOS Keychain
```

The host allowlist for interception is derived directly from this config — we only MITM hosts where we have a credential to inject.

---

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Interception mechanism | SNI-based at TCP forwarder | Authoritative (client's actual target), no DNS coupling |
| Non-matching traffic | Blind TCP passthrough | Zero overhead for non-intercepted connections |
| Key algorithm | ECDSA P-256 | Sub-ms key generation (vs ~100ms for RSA-2048) |
| Cert validity | 24 hours | Short-lived, no revocation infrastructure needed |
| CA lifecycle | Generated at sidecar startup, held in memory | No persistence needed; sidecar restart = new CA = re-provision guest trust |
| HTTP/2 support | Automatic via ALPN | `net/http.Server` dispatches based on negotiated protocol |
| SSE streaming | Automatic via ReverseProxy | Detects `text/event-stream`, flushes immediately |
| Host allowlist | Derived from credential config | Only intercept hosts where we have credentials to inject |
| Library embedding | Lima pattern (Go library, not subprocess) | Single process, no IPC overhead |

---

## What This Stack Does NOT Handle (Out of Scope)

| Concern | Status | Notes |
|---------|--------|-------|
| Network egress control (blocking unauthorized hosts) | Separate concern | Can be added at the TCP forwarder level independently |
| Audit logging of proxied requests | Not included | Straightforward to add in the Director or a `ModifyResponse` callback |
| OAuth token refresh | Not included | Credential store could be extended |
| Multiple VMs sharing one sidecar | Not designed for | One sidecar per VM (gvisor-tap-vsock is per-VM) |
| Encrypted ClientHello (ECH) | Future risk | Mitigatable: sidecar controls guest DNS, can suppress HTTPS/SVCB records carrying ECH configs |
| Guest CA trust provisioning | Config only | nix-darwin activation script; exact mechanics need prototyping |

---

## Sources

- [Go stdlib MITM feasibility report](go-stdlib-mitm-feasibility.md) — detailed validation of each stdlib component
- [TLS interception approaches](tls-interception-approaches.md) — CA injection, cert pinning assessment, production patterns
