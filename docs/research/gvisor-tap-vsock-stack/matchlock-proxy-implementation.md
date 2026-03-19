# Matchlock Implementation Stack: Network Interception on macOS

This document provides a detailed overview of how Matchlock implements its transparent forward proxy and credential-injecting MITM interceptor on macOS.

---

## Architecture Overview

Instead of relying on an off-the-shelf tunneling library like `gvisor-tap-vsock` or `httputil.ReverseProxy`, Matchlock implements a highly customized network stack by directly integrating Apple's Virtualization framework (`Code-Hex/vz`) with the low-level `gvisor.dev/gvisor/pkg/tcpip` primitives, and handling HTTP/TLS manually.

```
Guest VM (macOS VZ)
    |
    | raw Ethernet frames over UNIX Socket Pair
    | (VZFileHandleNetworkDeviceAttachment via Code-Hex/vz)
    |
    v
┌─────────────────────────────────────────────────────────────┐
│  Host-side Matchlock Daemon (single Go process)             │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Custom Network Stack (`pkg/net/stack_darwin.go`)     │  │
│  │                                                       │  │
│  │  ┌─────────┐  ┌───────┐ ┌──────────────┐              │  │
│  │  │ Socket  │  │ DNS   │ │ TCP forwarder│              │  │
│  │  │ Pair    │  │ Proxy │ │ (per-port    │              │  │
│  │  │ Endpoint│  │       │ │  routing)    │              │  │
│  │  └─────────┘  └───────┘ └──────┬───────┘              │  │
│  │       gVisor netstack (userspace TCP/IP)              │  │
│  └────────────────────────────────┼──────────────────────┘  │
│                                   │                         │
│                    ┌──────────────┼──────────────┐          │
│                    │              │              │          │
│               Port 80/443      Other Ports       │          │
│                    │              │              │          │
│                    v              v              │          │
│          ┌───────────────────┐  ┌───────────┐    │          │
│          │ HTTPInterceptor   │  │ TCP Proxy │    │          │
│          │ (TLS termination) │  │ Passthru  │    │          │
│          └─────────┬─────────┘  └─────┬─────┘    │          │
│                    │                  │          │          │
│          ┌─────────v─────────┐        │          │          │
│          │ http.ReadRequest  │        │          │          │
│          │ (HTTP/1.1 only)   │        │          │          │
│          └─────────┬─────────┘        │          │          │
│                    │                  │          │          │
│          ┌─────────v─────────┐        │          │          │
│          │ policy.Engine     │        │          │          │
│          │ - token swap      │        │          │          │
│          │ - header mutate   │        │          │          │
│          └─────────┬─────────┘        │          │          │
│                    │                  │          │          │
│          ┌─────────v─────────┐        │          │          │
│          │ UpstreamConnPool  │        │          │          │
│          │ + net/tls.Dial    │        │          │          │
│          └─────────┬─────────┘        │          │          │
│                    │                  │          │          │
│                    v                  v          │          │
│             Real Upstream       Real Upstream    │          │
└──────────────────────────────────────────────────┴──────────┘
```

---

## Complete Component Table

| # | Component | What it does | Provided by | Custom code |
|---|-----------|-------------|-------------|-------------|
| | **Network layer** | | | |
| 1 | VM NIC attachment | Connects guest virtual NIC to host via unix socket pair | `vz.NewFileHandleNetworkDeviceAttachment` | ~10 lines |
| 2 | Ethernet frame I/O | Reads/writes bare L2 frames over socket pair | Custom `socketPairEndpoint` | ~120 lines |
| 3 | Userspace TCP/IP | Parses Ethernet → IP → TCP/UDP, reassembles streams | gVisor `tcpip` stack | ~20 lines |
| 4 | IP Routing & DHCP | No DHCP used; static IP routing and MAC addressing | gVisor `stack.SetRouteTable` | ~10 lines |
| 5 | DNS proxy | Intercepts UDP port 53, forwards to host DNS servers | Custom `handleDNS` | ~25 lines |
| | **Interception layer** | | | |
| 6 | TCP forwarder | Routes connections to passthrough vs intercept based on port | gVisor `tcp.NewForwarder` + Custom hook | ~25 lines |
| 7 | Guest-side net.Conn | Go `net.Conn` adapter for gVisor TCP connection | `gonet.NewTCPConn` | 0 lines |
| 8 | Intercept decision | Intercepts ALL traffic unconditionally on ports 80 and 443 | Custom (switch statement on `dstPort`) | ~5 lines |
| 9 | TCP passthrough | Blind bidirectional copy for non-80/443 ports | Custom (`handlePassthrough` with `io.Copy`) | ~30 lines |
| | **TLS MITM layer** | | | |
| 10 | TLS termination | Accepts TLS from guest, presents dynamic certs via `GetCertificate` | `crypto/tls.Server` | ~15 lines |
| 11 | Dynamic cert gen | Generates RSA-2048 leaf cert for the target SNI | `crypto/x509.CreateCertificate` | ~30 lines |
| 12 | Certificate cache | Caches generated certs by hostname | Custom `sync.Map` | ~15 lines |
| 13 | CA key pair | RSA-2048 CA certificate generated at sidecar startup | Custom `generateCA` | ~30 lines |
| | **HTTP layer** | | | |
| 14 | HTTP/1.1 parsing | Parses HTTP requests directly from standard connection | `net/http.ReadRequest` | ~5 lines |
| 15 | HTTP/2 support | None (ALPN omitted, forces downgrade to HTTP/1.1) | N/A | 0 lines |
| 16 | Upstream proxy | Connection pool for HTTP/1.1 keep-alive reuse to real upstream | Custom `upstreamConnPool` | ~80 lines |
| | **Credential injection** | | | |
| 17 | Token replacement | Swaps placeholder in headers and URL params (skips body) | Custom `policy.Engine.replaceInRequest` | ~20 lines |
| 18 | Host allowlist | Verifies destination host against `NetworkConfig.AllowedHosts` | Custom `policy.Engine.isHostAllowed` | ~15 lines |
| 19 | Hooks & mutations | Applies SDK callbacks to mutate HTTP request/response | Custom `policy.Engine.OnRequest`/`OnResponse` | ~30 lines |
| | **Response handling** | | | |
| 20 | SSE/Chunked streams | Detects `text/event-stream` or `chunked`, streams body without buffering | Custom `writeResponseHeadersAndStreamBody` | ~40 lines |
| 21 | Standard responses | Buffers and writes complete response to guest | Custom `writeResponse` | ~10 lines |
| 22 | TLS to upstream | Establishes TLS to real API server | `tls.Dial` | ~5 lines |
| | **Guest trust** | | | |
| 23 | CA cert injection | CA cert written directly to overlay rootfs at `/etc/ssl/certs` | Custom `injectConfigFileIntoRootfs` | ~5 lines |
| 24 | Env var injection | Sets `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, etc. for running processes | Custom `prepareExecEnv` | ~10 lines |

---

## Dependency Chain

Matchlock relies entirely on first-party tools and deep stdlib/gVisor integration rather than high-level reverse proxies.

| Dependency | Source | What it does |
|-----------|--------|-------------------|
| `github.com/Code-Hex/vz/v3` | Virtualization framework | Maps macOS virtual NIC to host file descriptors. |
| `gvisor.dev/gvisor/pkg/tcpip` | gVisor Netstack | Implements L2-L4 networking (ARP, IP, TCP, UDP). |
| `gvisor.dev/gvisor/pkg/tcpip/adapters/gonet` | gVisor Netstack | Adapts gVisor TCP/UDP endpoints into `net.Conn`. |
| `crypto/tls` | Go stdlib | Handles all TLS termination and upstream dialing. |
| `crypto/x509` | Go stdlib | Certificate generation. |
| `net/http` | Go stdlib | Used *only* for `ReadRequest` and `ReadResponse`. |

---

## Key Design Decisions (How it differs from the reference architecture)

1. **Direct gVisor Interfacing over `gvisor-tap-vsock`:** Matchlock does not use the high-level `gvisor-tap-vsock` package. It implements a raw `stack.LinkEndpoint` (`socketPairEndpoint`) that reads Ethernet frames directly from the Unix socket pair connected to the macOS `VZFileHandleNetworkDeviceAttachment` and passes them immediately to the low-level gVisor `tcpip` stack.
2. **No DHCP Server:** Apple VZ's network handles static routing implicitly; Matchlock configures `tcpip.Stack` with a hardcoded default IPv4 gateway and interceptor logic. 
3. **DNS is proxied, not hosted:** Rather than running a full DNS zone server, Matchlock catches UDP port 53 traffic, parses nothing, and just blindly forwards the UDP packets to the host machine's configured DNS servers.
4. **MITM by Default (No SNI peeking):** There is no passive "SNI peeking" using `tcpproxy`. If interception is enabled, **all** TCP port 443 traffic is unceremoniously terminated via `tls.Server`. If the terminated host isn't in the allow-list, the connection is dropped post-handshake.
5. **No HTTP/2 Support (Explicit Downgrade):** Because Matchlock uses raw `bufio.Reader` and `http.ReadRequest` directly against the TLS connection, it does not negotiate ALPN (NextProtos). All guest HTTPS traffic gracefully falls back to HTTP/1.1.
6. **No `httputil.ReverseProxy`:** Matchlock opts to parse requests, apply policy rules (like replacing `SANDBOX_SECRET_XXX` in headers and URLs), dial upstream itself, and manually stream the bytes back (`writeResponseHeadersAndStreamBody`), rather than using `httputil.ReverseProxy`.
7. **RSA over ECDSA:** The CA and leaf certificates are generated using RSA-2048 instead of ECDSA P-256. 
8. **Guest Trust injection via Rootfs:** Instead of running shell commands inside the guest to update system keychain trusts, Matchlock writes the dynamically generated CA cert directly into the `/upper/etc/ssl/certs/matchlock-ca.crt` layer of the overlay filesystem before the VM boots, and automatically sets standard `SSL_CERT_FILE` and `NODE_EXTRA_CA_CERTS` environment variables for all sandboxed process executions.
