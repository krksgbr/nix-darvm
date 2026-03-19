# TLS Interception Approaches for Credential Injection

Research conducted 2026-03-19. Covers TLS MITM mechanics, CA injection into macOS VMs, library options, certificate pinning risks, production patterns, and practical implementation considerations.

---

## Table of Contents

1. [How TLS MITM Proxies Work](#1-how-tls-mitm-proxies-work)
2. [CA Certificate Injection into macOS Guest VM](#2-ca-certificate-injection-into-macos-guest-vm)
3. [Certificate Generation Libraries](#3-certificate-generation-libraries)
4. [Certificate Pinning Risk Assessment](#4-certificate-pinning-risk-assessment)
5. [Performance Overhead](#5-performance-overhead)
6. [SNI-Based Selective Interception](#6-sni-based-selective-interception)
7. [Alternative: Out-of-Band Token Replacement](#7-alternative-out-of-band-token-replacement)
8. [Production System Patterns](#8-production-system-patterns)
9. [Go and Rust Library Options](#9-go-and-rust-library-options)
10. [Certificate Management Lifecycle](#10-certificate-management-lifecycle)
11. [Error Handling and Failure Modes](#11-error-handling-and-failure-modes)
12. [Recommendations for Our Architecture](#12-recommendations-for-our-architecture)

---

## 1. How TLS MITM Proxies Work

### The Core Mechanism

A TLS MITM proxy interposes itself between client and server, establishing two separate TLS sessions:

1. **Client-to-proxy session**: The proxy presents a dynamically generated certificate for the target domain, signed by a CA that the client trusts.
2. **Proxy-to-server session**: The proxy connects to the real upstream server using standard TLS, appearing as a normal client.

Between these two sessions, the proxy has access to the plaintext HTTP layer -- headers, body, everything. This is where credential injection happens.

### Detailed Flow (Transparent Mode)

mitmproxy's implementation is the canonical reference. The transparent HTTPS flow works in eight steps:

1. **Traffic redirection**: At the network layer (iptables, pf, or in our case, the userspace TCP/IP stack), traffic destined for a remote server is routed to the proxy without any client configuration.
2. **Original destination discovery**: The routing mechanism reveals the original target IP and port.
3. **Client TLS initiation**: The client sends a `ClientHello` message containing the SNI (Server Name Indication) field with the target hostname.
4. **Upstream connection**: The proxy establishes its own TLS connection to the real server, using the SNI hostname from step 3.
5. **Certificate sniffing**: The real server presents its certificate. The proxy extracts the Common Name (CN), Subject Alternative Names (SANs), and Organization from this certificate.
6. **Interception certificate generation**: The proxy dynamically generates a new certificate containing the same CN and SANs, signed by the MITM CA. It then completes the paused TLS handshake with the client using this forged certificate.
7. **Plaintext relay**: The client sends its HTTP request (now decrypted). The proxy can read, modify, and forward it.
8. **Response relay**: The server's response flows back through both TLS sessions.

### Explicit vs. Transparent Mode

| Aspect | Explicit (HTTP CONNECT) | Transparent |
|--------|------------------------|-------------|
| Client awareness | Client knows it's using a proxy | Client is unaware |
| Configuration | Requires `HTTP_PROXY`/`HTTPS_PROXY` | Requires network-level redirection |
| Destination discovery | From the CONNECT request | From routing mechanism or SNI |
| Applicability | Only apps that respect proxy env vars | All TCP traffic |

**For our use case, transparent mode is required.** The product requirement explicitly states that guest tools should work without modification. Many tools (curl, SDKs, CLI tools) respect proxy env vars, but not all do, and configuring them reliably in all environments is fragile.

### Protocol Detection

mitmproxy performs automatic TLS detection by looking for a `ClientHello` message at the start of the connection, independent of the TCP port. This means it correctly handles TLS on non-443 ports and passes through non-TLS connections.

Sources:
- [How mitmproxy works](https://docs.mitmproxy.org/stable/concepts/how-mitmproxy-works/)
- [mitmproxy certificates](https://docs.mitmproxy.org/stable/concepts/certificates/)

---

## 2. CA Certificate Injection into macOS Guest VM

This is one of the trickiest parts of the architecture. The MITM proxy generates certificates signed by a custom CA, and the guest must trust this CA.

### Methods for Installing a Trusted CA on macOS

#### Method A: `security add-trusted-cert` (CLI)

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /path/to/ca-cert.pem
```

**Critical limitation on modern macOS**: Starting with macOS Big Sur (11+), Apple hardened certificate trust. Running as root alone is **no longer sufficient** to modify certificate trust settings -- the system requires an administrator password prompt. This is deliberate security hardening, not a bug.

However, there is a workaround: `security add-certificates` (note: plural, different command) can add a certificate to the System keychain *without* a password prompt. The trust must then be set separately, which is the step that requires interaction.

**For a VM where we control the initial image**: We can bake the CA certificate and its trust settings into the guest image at build time, before the VM is ever booted by a user. This avoids the runtime trust prompt entirely.

#### Method B: Configuration Profile (MDM-style)

Apple's recommended approach for programmatic certificate trust is to deploy a configuration profile (`.mobileconfig`) containing a `com.apple.security.root` payload. When installed via MDM, these are automatically trusted without user interaction.

For our use case: We're not running an MDM server, but macOS can install profiles from the command line:

```bash
/usr/bin/profiles install -path /path/to/cert-profile.mobileconfig
```

This may still require user confirmation on modern macOS.

#### Method C: Pre-baked Trust in the Guest Image (Recommended)

Since we control the guest macOS image build (via nix-darwin):

1. Generate the MITM CA cert and key at image build time.
2. Add the CA cert to the System keychain.
3. Set trust settings for the CA cert.
4. Bake the resulting keychain state into the base image.

This is the most robust approach because:
- No runtime prompts or interactions required.
- No dependency on MDM infrastructure.
- The trust state is part of the immutable base image.
- The CA private key never enters the guest -- only the public certificate does. The private key stays on the host where the proxy runs.

#### Method D: Environment Variables for Specific Tools

Many tools can be configured to trust a specific CA bundle via environment variables:

| Tool / Library | Environment Variable |
|---------------|---------------------|
| Python httpx | `SSL_CERT_FILE`, `SSL_CERT_DIR` |
| Python requests | `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE` |
| Node.js | `NODE_EXTRA_CA_CERTS` |
| curl | `CURL_CA_BUNDLE` |
| Go (net/http) | Uses system trust store by default |
| Ruby | `SSL_CERT_FILE` |

This approach is **fragile** -- it only works for tools that respect these variables, and each language ecosystem has different conventions. httpx (used by both OpenAI and Anthropic Python SDKs) uses certifi's bundled CA store by default, not the system trust store. Setting `SSL_CERT_FILE` overrides this, but it must point to a complete CA bundle (including standard CAs), not just our custom CA.

**Verdict**: Use pre-baked trust in the guest image (Method C) as the primary approach. Use environment variables (Method D) as a belt-and-suspenders supplement for tools known to ignore the system trust store.

#### nix-darwin Integration

There is no well-documented nix-darwin module for managing certificate trust. The practical approach is to use an activation script in the nix-darwin configuration that runs the `security` commands during system activation. Since the VM image is built from scratch, we can run these commands during the initial image build rather than at runtime.

Sources:
- [Trusting Certificates in System Keychain without Prompting](https://twocanoes.com/trusting-certificates-in-system-keychain-without-prompting/)
- [Adding new trusted root certificates to System.keychain](https://derflounder.wordpress.com/2011/03/13/adding-new-trusted-root-certificates-to-system-keychain/)
- [Apple Developer Forums: security add-trusted-cert](https://developer.apple.com/forums/thread/671582)
- [HTTPX SSL documentation](https://www.python-httpx.org/advanced/ssl/)

---

## 3. Certificate Generation Libraries

### What Dynamic Cert Generation Requires

When a client connects to `api.openai.com:443`, the proxy must:

1. Extract the SNI hostname from the `ClientHello`.
2. Optionally connect to the upstream to sniff the real certificate's CN/SANs.
3. Generate a new X.509 certificate with matching CN/SANs, signed by the MITM CA.
4. Complete the TLS handshake with the client using this certificate.
5. Cache the generated certificate for reuse on subsequent connections to the same host.

### Go Libraries

| Library | Stars | Approach | Notes |
|---------|-------|----------|-------|
| [elazarl/goproxy](https://github.com/elazarl/goproxy) | ~6k | Full proxy lib | Integrated MITM with `SetMITMCertConfig()`. Supports transparent mode via `ListenAndServe`. `HandleConnect` callback decides per-connection whether to MITM. |
| [AdguardTeam/gomitmproxy](https://github.com/AdguardTeam/gomitmproxy) | ~500 | Full proxy lib | Created for AdGuard Home. In-memory cert cache. `MITMExceptions` list for bypassing hosts. `OnRequest`/`OnResponse` handlers for modification. **Does not support transparent proxying out of the box** -- designed for explicit proxy mode. |
| [lqqyt2423/go-mitmproxy](https://github.com/lqqyt2423/go-mitmproxy) | ~1k | Full proxy lib | Python mitmproxy-inspired. Web UI. On-the-fly cert generation. |
| [kardianos/mitmproxy](https://pkg.go.dev/github.com/kardianos/mitmproxy) | Small | Library | Minimal Go MITM proxy package. |
| Go stdlib `crypto/x509` + `crypto/tls` | N/A | Manual | Full control. Generate certs with `x509.CreateCertificate()`, use `tls.Config.GetCertificate` callback for on-demand generation. More code, but no dependency on third-party proxy libraries. |

**For Design A (gvisor-tap-vsock sidecar)**: We don't need an HTTP proxy library at all. We need raw TLS termination at the TCP level. Once the userspace TCP/IP stack reassembles a TCP connection, we:
1. Check the SNI from the `ClientHello`.
2. If it matches a target host, perform TLS termination using Go's `crypto/tls` with a dynamic `GetCertificate` callback.
3. Read the plaintext HTTP, perform token replacement, and forward over a new TLS connection to the upstream.

This means `crypto/x509` + `crypto/tls` from the Go stdlib may be sufficient, without needing goproxy or gomitmproxy.

### Rust Libraries

| Library | Approach | Notes |
|---------|----------|-------|
| [rustls/rcgen](https://github.com/rustls/rcgen) | X.509 cert generation | Generate CA certs and leaf certs programmatically. Pure Rust. Well-maintained (part of the rustls ecosystem). |
| [rustls-cert-gen](https://lib.rs/crates/rustls-cert-gen) | Higher-level wrapper | Wraps rcgen for simpler TLS certificate chain generation. |
| [http-mitm-proxy](https://lib.rs/crates/http-mitm-proxy) | Full MITM proxy | Integrates rcgen for on-the-fly cert generation. Designed as a Burp-style proxy backend. |
| rustls + rcgen | Manual | Combine rustls for TLS handling with rcgen for cert generation. Full control. |

Sources:
- [goproxy documentation](https://pkg.go.dev/github.com/elazarl/goproxy)
- [gomitmproxy](https://github.com/AdguardTeam/gomitmproxy)
- [rcgen](https://github.com/rustls/rcgen)
- [http-mitm-proxy crate](https://lib.rs/crates/http-mitm-proxy)

---

## 4. Certificate Pinning Risk Assessment

Certificate pinning is the critical risk for any TLS MITM approach. If a client pins a specific certificate or public key, it will reject our MITM-generated certificates regardless of whether our CA is trusted.

### Target API SDKs Assessment

#### OpenAI Python SDK
- Uses **httpx** under the hood.
- httpx uses **certifi** for certificate verification by default.
- **No certificate pinning.** The SDK trusts any certificate signed by a CA in the certifi bundle (or the system trust store if configured).
- Respects `SSL_CERT_FILE` and `SSL_CERT_DIR` environment variables.
- Custom `httpx.Client(verify=...)` can be passed to the SDK constructor.
- Enterprise users commonly use this SDK behind corporate TLS-intercepting proxies, confirming no pinning.

#### Anthropic Python SDK
- Also uses **httpx** under the hood.
- Same certificate verification behavior as OpenAI SDK.
- **No certificate pinning.**
- The SDK supports custom httpx client injection for mTLS and custom CA scenarios.
- Claude Code itself supports custom CA certificates via `NODE_EXTRA_CA_CERTS`.

#### GitHub CLI (`gh`)
- Written in Go.
- Uses Go's `net/http` which trusts the **system certificate store** by default.
- **No certificate pinning.**
- Go applications on macOS use the macOS Keychain trust store, meaning our pre-baked CA will be trusted.

#### curl
- Uses the system or bundled CA store (depending on how it was built).
- **No certificate pinning** (unless explicitly configured with `--pinnedpubkey`).
- Homebrew curl on macOS uses the macOS trust store.

#### Node.js (for Claude Code, npm, etc.)
- Uses a compiled-in CA store by default.
- `NODE_EXTRA_CA_CERTS` adds additional trusted CAs.
- **No certificate pinning** in the runtime itself.

### Verdict on Certificate Pinning

**None of our target clients pin certificates.** This is expected -- certificate pinning is primarily used by:
- Mobile apps communicating with their own backend
- High-security financial applications
- Browser-to-server communications (via HPKP, now deprecated)

General-purpose API SDKs and CLI tools **do not pin** because they need to work in corporate environments with TLS-intercepting proxies, custom CAs, and other enterprise infrastructure. The OpenAI and Anthropic community forums are full of users dealing with corporate proxy certificate issues -- which confirms these SDKs are designed to work with custom trust stores.

**Risk level: Low.** The MITM approach will work for all known target clients.

### Potential Future Risks

- A future SDK version could introduce pinning (extremely unlikely for the reasons above).
- Some edge-case tools might bundle their own CA store and ignore system trust (Python's certifi does this, but respects `SSL_CERT_FILE`).
- If a user installs a custom tool that does pin, those connections will fail. This is acceptable -- we should document it and provide a bypass mechanism (passthrough for unknown tools).

Sources:
- [OpenAI SSL certificate issues](https://community.openai.com/t/ssl-certificate-verify-failed/32442)
- [Anthropic SSL Certificate Error diagnosis](https://drdroid.io/integration-diagnosis-knowledge/anthropic-ssl-certificate-error)
- [Claude Code enterprise network configuration](https://code.claude.com/docs/en/network-config)
- [HTTPX SSL documentation](https://www.python-httpx.org/advanced/ssl/)

---

## 5. Performance Overhead

### The Double TLS Tax

A MITM proxy performs TLS termination (decrypt) and TLS origination (re-encrypt) for every intercepted connection. This means:

- **2x TLS handshakes** per new connection (one client-side, one server-side).
- **2x symmetric encryption/decryption** for every byte of application data.
- **Certificate generation** on first connection to each new host (amortized by caching).

### Benchmarks from Literature

Research from Meta's mmTLS system (USENIX ATC 2024) found that a naive split-TLS (MITM) architecture **degrades throughput by up to 71%** compared to end-to-end TLS. Their optimized mmTLS system achieved 2.7-3.1x higher throughput than the naive approach.

However, for our use case, the relevant metric is **latency per request**, not bulk throughput:

- **TLS handshake overhead**: ~5-10ms per handshake on modern hardware with TLS 1.3. With connection reuse (HTTP/1.1 keep-alive or HTTP/2), this is a one-time cost.
- **Symmetric crypto overhead**: Negligible for API request/response sizes. AES-GCM on ARM64 (Apple Silicon) uses hardware acceleration. For a typical API request (a few KB) and response (a few KB to a few hundred KB), the crypto overhead is sub-millisecond.
- **Certificate generation**: ~1-5ms for RSA-2048 or ECDSA-P256 signing. Cached after first generation per host.

### Practical Impact for Our Use Case

Our interception targets are API calls to Anthropic, OpenAI, GitHub, etc. These are:
- **Low frequency**: Typically a few requests per second at most.
- **High latency**: API calls to these services already take 100ms-10s+ (especially LLM inference calls).
- **Small payloads for injection**: We're only modifying a single header value.

The MITM overhead (a few milliseconds per request) is **completely negligible** relative to the inherent latency of these API calls. This is not a performance concern.

### Optimizations Worth Implementing

1. **TLS session resumption**: Reuse TLS sessions for repeated connections to the same host. Go's `crypto/tls` supports this natively.
2. **Certificate caching**: Cache generated certificates keyed by hostname. All proxy libraries do this by default.
3. **Connection pooling**: Reuse upstream TLS connections when possible (HTTP keep-alive).
4. **ECDSA over RSA**: Use ECDSA-P256 for generated certificates -- faster signing than RSA-2048.
5. **Passthrough for non-target hosts**: Don't terminate TLS for connections we don't need to inspect. Just relay the raw TCP bytes.

Sources:
- [mmTLS: Scaling the Performance of Encrypted Network Traffic (USENIX ATC 2024)](https://www.usenix.org/system/files/atc24-yoon.pdf)
- [Is TLS Fast Yet?](https://istlsfastyet.com/)

---

## 6. SNI-Based Selective Interception

### The Principle

Not all connections need interception. We only need to MITM connections to known API hosts where credential injection applies. Everything else should pass through untouched.

SNI (Server Name Indication) is an extension to TLS that sends the target hostname in plaintext during the `ClientHello` message. This gives us a decision point before any TLS termination occurs.

### Decision Flow

```
Incoming TCP connection
    |
    +-- Read ClientHello, extract SNI
    |
    +-- SNI matches target host list?
    |       |
    |       YES --> TLS MITM (terminate, inspect, inject, re-encrypt)
    |       |
    |       NO  --> TCP passthrough (relay raw bytes, no crypto overhead)
    |
    +-- No ClientHello / no SNI?
            |
            +-- TCP passthrough (assume non-TLS or unknown)
```

### Target Host List

For credential injection, we need to intercept connections to specific API endpoints:

```
api.anthropic.com
api.openai.com
api.github.com
*.githubusercontent.com    (for GitHub API)
pypi.org                   (if injecting PyPI tokens)
registry.npmjs.org         (if injecting npm tokens)
```

This is an **allowlist** approach: we only intercept what we know we need to. Everything else passes through.

### Allowlist vs. Denylist

| Approach | Pros | Cons |
|----------|------|------|
| **Allowlist** (intercept only listed hosts) | Minimal MITM surface. Predictable behavior. No surprise breakage. | Must maintain the list. New API hosts require configuration. |
| **Denylist** (intercept everything except listed hosts) | Catches all API traffic. No maintenance for new hosts. | Huge MITM surface. May break tools with unexpected TLS requirements. Performance overhead on all connections. |

**Allowlist is strictly better for our use case.** Our credential mappings already define which hosts get which credentials, so the interception list is derived directly from the credential configuration.

### Identification Methods

| Method | When Available | Reliability |
|--------|---------------|-------------|
| **SNI** | In the TLS `ClientHello` | High. Nearly all modern TLS clients send SNI. Required for HTTP/2 and virtual hosting. |
| **Destination IP** | At TCP connection time | Low. IPs change (CDN, load balancers). Multiple services may share IPs. |
| **DNS query** | Before connection | Medium. Requires running the guest's DNS server (which we do in Design A). Can correlate DNS lookups with subsequent TCP connections. |

**SNI is the primary identification method.** It's available before we need to make the MITM/passthrough decision, and it's the actual hostname the client intends to connect to.

### Implementation in gvisor-tap-vsock (Design A)

In Design A, the sidecar owns the guest's entire network. The flow is:

1. Guest sends raw Ethernet frames via the `VZFileHandleNetworkDeviceAttachment` file descriptor.
2. The sidecar's userspace TCP/IP stack (gvisor netstack) reassembles TCP connections.
3. For new TCP connections to port 443, peek at the first bytes to read the `ClientHello` and extract SNI.
4. If SNI matches the target list, perform TLS MITM. Otherwise, proxy the raw TCP bytes to the upstream.

This is the natural integration point. gvisor-tap-vsock already has a mechanism for forwarding TCP connections; we add a decision layer based on SNI.

Sources:
- [SSLproxy: Transparent SSL/TLS proxy](https://github.com/sonertari/SSLproxy)
- [go-transparenttlsproxy: Transparent TLS proxy using SNI](https://github.com/iamacarpet/go-transparenttlsproxy)
- [SSLsplit: transparent SSL/TLS interception](https://www.roe.ch/SSLsplit)

---

## 7. Alternative: Out-of-Band Token Replacement

### Could We Avoid TLS MITM Entirely?

The placeholder token appears in HTTP headers (e.g., `Authorization: Bearer SANDBOX_SECRET_7a3f9b2e...`). To replace it, we need to see the plaintext HTTP. TLS encrypts the HTTP layer, so we need TLS termination.

Alternative approaches that avoid TLS MITM:

#### 7a. Custom TLS Client in the Guest

The guest could use a modified TLS client that signals credentials out-of-band (e.g., over vsock). The proxy on the host would receive the signal and inject the real credential.

**Problems**:
- Violates the transparency requirement. Every tool in the guest would need to use this custom client.
- Massive integration burden. Each SDK, CLI tool, curl invocation would need modification.
- **Not viable.**

#### 7b. Pre-Request Hook via vsock

Before making an HTTPS request, the guest tool sends the request details to the host over vsock, receives back the modified headers, then makes the actual HTTPS request itself.

**Problems**:
- Still requires tool modification. Not transparent.
- The guest would have the real credential briefly (received from the host, used in the TLS connection).
- **Not viable** for transparency or security requirements.

#### 7c. Token Exchange at DNS Level

The guest resolves `api.openai.com` to a local proxy (via DNS override). The proxy terminates TLS and does the injection. This is essentially the MITM approach but with DNS as the redirection mechanism.

**This is still TLS MITM** -- just with a different routing mechanism. Not a true alternative.

### Verdict

There is no practical way to do transparent credential injection into HTTPS traffic without TLS interception. The plaintext HTTP layer is only accessible between the two TLS sessions. TLS MITM is the only approach that meets the transparency requirement.

---

## 8. Production System Patterns

### Envoy Gateway: Credential Injector Filter

Envoy (used in Istio, Envoy Gateway, and many service meshes) has a first-class **credential injector filter** that is directly analogous to our use case.

**How it works:**
- The credential injector filter runs in the HTTP filter chain, after TLS termination.
- It fetches credentials from a configured source (Kubernetes Secrets, OAuth2 token endpoints, etc.).
- It injects credentials into request headers -- by default the `Authorization` header, but configurable to any header.
- It respects existing headers: won't overwrite unless `overwrite: true` is set.
- It's designed for **workload authentication** -- the injected credential represents the identity of the workload behind the proxy.

**Key configuration options:**
- `allow_request_without_credential`: Whether to pass requests through if credential injection fails.
- `overwrite`: Whether to replace existing credentials.
- Supports Basic, Bearer, and custom header injection.
- OAuth2 mode: Automatically fetches and refreshes tokens from a token endpoint.

**Relevance to our design:** Envoy's approach validates our architecture. The pattern is: terminate TLS, run an HTTP filter that inspects/modifies headers, then originate a new TLS connection upstream. This is exactly what we're doing, just in a VM networking context rather than a Kubernetes pod context.

### Istio Service Mesh: mTLS Sidecar

Istio's sidecar proxy (Envoy) MITMs all traffic within the mesh:

1. Each pod gets an Envoy sidecar.
2. All outbound traffic is redirected to the sidecar via iptables rules.
3. The sidecar terminates the connection and establishes a new mTLS connection to the destination's sidecar.
4. Along the way, it can inject headers, enforce policies, and collect telemetry.

**Relevance**: This is the same pattern as our Design A, but in a Kubernetes context. The sidecar owns the pod's network, terminates TLS, and can inject/modify headers. Our sidecar owns the VM's network via the userspace TCP/IP stack.

### Cloudflare Workers: Edge Credential Injection

Cloudflare Workers solve a related problem: injecting API keys at the edge so clients never see them.

- A Worker intercepts requests, reads secrets from the Secrets Store, adds the API key to the request, and forwards to the backend.
- Secrets are encrypted at rest and in transit.
- Workers run after TLS termination (Cloudflare terminates TLS at its edge).

**Relevance**: Validates the "intercept, inject, forward" pattern. In their case, TLS termination happens at Cloudflare's edge; in ours, it happens at the host-side proxy.

### Docker Desktop: VPNKit / gvisor-tap-vsock

Docker Desktop's networking architecture is the closest production analog to our Design A:

- **VPNKit** (original, written in OCaml/MirageOS) reads raw Ethernet frames from the Linux VM and translates them into host-level socket calls.
- **gvisor-tap-vsock** (replacement, written in Go) does the same thing using gVisor's netstack.
- Docker Desktop 4.19+ on macOS 13+ uses gvisor-tap-vsock instead of VPNKit.

Docker Desktop uses this architecture for:
- HTTP proxy forwarding (inheriting the host's proxy settings).
- DNS resolution.
- VPN compatibility (routing VM traffic through the host's VPN).

**Docker Desktop does NOT perform TLS MITM.** It proxies raw TCP connections. But the architecture (userspace TCP/IP stack receiving raw frames from a VM) is identical to what we'd build for Design A. We'd add TLS termination on top.

Sources:
- [Envoy Gateway: Credential Injection](https://gateway.envoyproxy.io/docs/tasks/security/credential-injection/)
- [Envoy Credential Injector Filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/credential_injector_filter)
- [Istio Architecture](https://istio.io/latest/docs/ops/deployment/architecture/)
- [Cloudflare Workers Secrets](https://developers.cloudflare.com/workers/configuration/secrets/)
- [How Docker Desktop Networking Works Under the Hood](https://www.docker.com/blog/how-docker-desktop-networking-works-under-the-hood/)
- [How MirageOS Powers Docker Desktop](https://mirage.io/blog/2022-04-06.vpnkit)

---

## 9. Go and Rust Library Options

### Go Libraries for TLS MITM

#### Option 1: Go stdlib (`crypto/tls` + `crypto/x509`)

For Design A (gvisor-tap-vsock sidecar), we operate at the TCP connection level, not the HTTP proxy level. We can build TLS interception directly on the stdlib:

```go
// Simplified pseudocode
tlsConfig := &tls.Config{
    GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
        // hello.ServerName contains the SNI hostname
        // Generate or retrieve cached cert for this hostname
        return generateCert(hello.ServerName, caCert, caKey)
    },
}
```

**Pros**: No external dependencies. Full control. Matches our architecture (TCP-level, not HTTP-proxy-level). Go's TLS implementation is well-tested and production-grade.

**Cons**: More code to write. Must handle HTTP parsing ourselves (though `net/http` can read from any `io.Reader`).

#### Option 2: elazarl/goproxy

Supports transparent MITM proxying. The `HandleConnect` callback can decide per-host whether to MITM or pass through. Integrated certificate generation.

**Pros**: Battle-tested. Good API for request/response modification.

**Cons**: Designed as an HTTP proxy, not a TCP-level interceptor. May not integrate cleanly with gvisor-tap-vsock's connection model. Adds dependency complexity.

#### Option 3: AdguardTeam/gomitmproxy

Clean API with `OnRequest`/`OnResponse` handlers. Certificate caching built in. `MITMExceptions` for bypass.

**Pros**: Well-maintained (AdGuard is a real product). Clean API.

**Cons**: **Does not support transparent proxy mode.** Designed for explicit proxy (CONNECT-based). Would need significant modification for our use case.

#### Recommendation for Go

**Use Go stdlib.** In Design A, the sidecar already has raw TCP connections from the userspace stack. Adding TLS termination with `crypto/tls` and certificate generation with `crypto/x509` is straightforward. Using an HTTP proxy library would be fighting the architecture -- we don't have an HTTP proxy, we have a TCP connection interceptor that needs to do TLS termination on select connections.

For HTTP parsing after TLS termination, use `net/http.ReadRequest()` and `net/http.Response.Write()`.

### Rust Libraries for TLS MITM

#### rcgen (Certificate Generation)

Part of the rustls ecosystem. Pure Rust. Generates X.509 certificates and CSRs. Can create CA certificates and sign leaf certificates.

```rust
// Simplified
let ca_params = CertificateParams::new(vec![]);
ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
let ca_cert = Certificate::from_params(ca_params)?;

let mut leaf_params = CertificateParams::new(vec!["api.openai.com".to_string()]);
let leaf_cert = Certificate::from_params(leaf_params)?;
let leaf_pem = leaf_cert.serialize_pem_with_signer(&ca_cert)?;
```

#### http-mitm-proxy

Full MITM proxy crate. Integrates rcgen. Designed as a Burp-style proxy backend.

**Pros**: Complete solution.
**Cons**: Designed for explicit proxy mode. May not fit our architecture.

#### Recommendation for Rust

If building any component in Rust, use **rcgen + rustls** for the TLS layer. The same "build on primitives" logic applies as with Go.

Sources:
- [goproxy](https://github.com/elazarl/goproxy)
- [gomitmproxy](https://github.com/AdguardTeam/gomitmproxy)
- [rcgen](https://github.com/rustls/rcgen)
- [http-mitm-proxy](https://crates.io/crates/http-mitm-proxy)

---

## 10. Certificate Management Lifecycle

### CA Generation

- Generate a unique CA certificate and private key **per VM instance** (or per VM image). This limits the blast radius if a CA key is compromised.
- Use ECDSA-P256 for the CA key. Faster signing than RSA, smaller certificates.
- Set a reasonable validity period for the CA (e.g., 1 year, or the expected VM lifetime).
- The CA key lives on the **host side only**. It never enters the guest VM.

### Leaf Certificate Generation

- Generate leaf certificates on-demand when a connection to a new host is first intercepted.
- Copy the CN and SANs from the real upstream certificate (certificate sniffing).
- Set short validity (e.g., 24 hours). These are ephemeral and cached in memory.
- Cache by hostname. Evict after expiry.

### Distribution

- The CA public certificate is baked into the guest image's trust store at build time.
- The CA private key is loaded by the host-side sidecar at startup.
- No runtime certificate distribution needed.

### Rotation

- For long-lived VMs, the CA certificate may expire. Two options:
  1. **Short-lived VMs**: If VMs are rebuilt frequently, CA rotation is automatic (new CA per image build).
  2. **Long-lived VMs**: Implement CA rotation by generating a new CA, updating the guest trust store (requires guest-side coordination), and switching the sidecar to the new CA. This is complex and should be avoided by preferring short-lived VM images.

### Revocation

- CRL/OCSP are not needed for our use case. The MITM CA is private and the only entity that trusts it is the guest VM. There's no public PKI to update.
- If the CA is compromised, destroy the VM and rebuild from a fresh image with a new CA.

### Security Considerations

- The CA private key is high-value. It should be stored securely on the host (e.g., macOS Keychain, or generated at startup and held only in memory).
- Consider generating the CA key at sidecar startup and holding it only in memory, never persisting to disk. This means a sidecar restart generates a new CA -- but for our use case, a sidecar restart likely means a VM restart anyway.

---

## 11. Error Handling and Failure Modes

### TLS Handshake Failures

| Failure | Cause | Handling |
|---------|-------|----------|
| Client rejects MITM cert | CA not trusted in guest | Fail loudly. Log the error. This is a configuration problem. |
| Upstream TLS failure | Server down, cert expired, etc. | Pass the TLS error back to the client as-is. Don't mask upstream failures. |
| SNI missing | Very old TLS client | Fall back to TCP passthrough. Cannot determine target host. |
| Certificate generation failure | Crypto error (unlikely) | Fail the connection. Log the error. |

### HTTP Parsing Failures

| Failure | Cause | Handling |
|---------|-------|----------|
| Malformed HTTP | Not HTTP traffic on port 443 | Fall back to TCP passthrough. |
| HTTP/2 or HTTP/3 | Different wire format | Must handle HTTP/2 (used by most API SDKs). HTTP/3 (QUIC) is UDP-based and won't be intercepted by our TCP-level proxy. |
| No placeholder token found | Legitimate request without credentials, or credentials in unexpected location | Pass through unmodified. Token replacement is a no-op if no placeholder is found. |

### Critical Design Principle: Fail Open vs. Fail Closed

For credential injection:
- **Fail open** (pass through unmodified) if token replacement fails or isn't applicable.
- **Fail closed** (block the connection) only if there's a security violation (e.g., real credentials detected leaving the guest, if we implement exfiltration detection).

The proxy should **never** swallow an error and silently drop a request. If something goes wrong, the client should see an error (even if it's a generic TLS error).

### HTTP/2 Considerations

Most API SDKs negotiate HTTP/2 when available. The proxy must:
1. Terminate the client-side TLS and handle ALPN negotiation.
2. Parse HTTP/2 frames (or upgrade to HTTP/2 with the upstream).
3. Inspect the `:authority` pseudo-header and `authorization` header within HTTP/2 HEADERS frames.
4. Perform token replacement within the HTTP/2 framing.

Go's `net/http` package handles HTTP/2 natively, including server-side HTTP/2 (for the client-facing connection) and client-side HTTP/2 (for the upstream connection). This significantly simplifies the implementation compared to manually parsing HTTP/2 frames.

---

## 12. Recommendations for Our Architecture

### TLS MITM is the Right Approach

There is no viable alternative for transparent credential injection into HTTPS traffic. The TLS MITM approach is:
- Used by every major interception tool (mitmproxy, Fiddler, Charles Proxy, Burp Suite).
- Used in production by service meshes (Istio/Envoy) for similar header injection.
- Used by Envoy Gateway's credential injector filter for exactly this pattern.
- Low risk for our target clients (no certificate pinning in any known target SDK).
- Negligible performance overhead for API traffic patterns.

### Design A is the Natural Fit for TLS MITM

Design A (host-side sidecar with gvisor-tap-vsock and `VZFileHandleNetworkDeviceAttachment`) is the best architecture for TLS interception because:

1. **Total network control**: The sidecar sees all guest traffic as raw Ethernet frames. No traffic can bypass it. This is a stronger guarantee than Network Extension approaches.
2. **SNI-based routing is trivial**: The sidecar reassembles TCP connections and can inspect the `ClientHello` before deciding to MITM or passthrough.
3. **Go stdlib is sufficient**: `crypto/tls` + `crypto/x509` + `net/http` provide everything needed for TLS termination, certificate generation, and HTTP parsing. No third-party proxy library is required.
4. **Docker Desktop validates the architecture**: Docker Desktop uses the identical networking approach (gvisor-tap-vsock for VM networking). We add TLS termination on top of their proven model.

### Implementation Approach

1. **Certificate lifecycle**:
   - Generate ECDSA-P256 CA at sidecar startup (or load from host keychain).
   - Bake CA public cert into guest image trust store at build time.
   - Generate leaf certificates on-demand with caching.

2. **Connection handling**:
   - For TCP connections to port 443, read the `ClientHello` and extract SNI.
   - If SNI matches the credential target list, perform TLS MITM.
   - If SNI does not match, TCP passthrough (zero overhead).

3. **Credential injection**:
   - After TLS termination, parse the HTTP request.
   - Scan for placeholder tokens in headers (Authorization, X-API-Key, etc.).
   - Replace with real credential values from the host-side credential store.
   - Forward over a new TLS connection to the real upstream.

4. **CA trust in the guest**:
   - Primary: Bake CA cert into the macOS system keychain in the guest image (nix-darwin activation script).
   - Supplementary: Set `SSL_CERT_FILE` and `NODE_EXTRA_CA_CERTS` environment variables pointing to a CA bundle that includes our custom CA alongside standard CAs. This catches tools that ignore the system trust store (e.g., Python httpx/certifi).

### Open Questions

1. **HTTP/2 handling**: Go's `net/http` handles HTTP/2 natively, but we need to verify it works correctly in the "TLS terminate, parse HTTP, modify, re-encrypt" flow. Specifically: can we use `http.ReadRequest` on a `tls.Conn` and get HTTP/2 for free, or do we need explicit HTTP/2 handling?

2. **CA key lifecycle**: Generate at startup and hold in memory, or persist and load? Memory-only is more secure but means a sidecar restart changes the CA (requiring guest trust store update).

3. **Connection pooling**: Should the sidecar maintain persistent upstream TLS connections to frequently-used API hosts (api.anthropic.com, api.openai.com)? This would amortize TLS handshake cost.

4. **Guest image CA injection mechanics**: Exact nix-darwin incantation for adding a CA to the macOS system trust store during image build. Needs prototyping.

5. **Encrypted ClientHello (ECH)**: TLS 1.3 with ECH encrypts the SNI. Not widely deployed yet, but if target APIs adopt it, our SNI-based routing would break. Mitigation: since we control the guest's DNS, we can suppress the ECH configuration in DNS responses.
