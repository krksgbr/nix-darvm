# Go Stdlib MITM Proxy Feasibility Report

**Date:** 2026-03-19
**Question:** Can Go's standard library serve as a near-complete MITM proxy for transparent credential injection?
**Verdict:** Yes. The entire chain works with stdlib + `golang.org/x/net/http2`. Custom code is roughly 200-300 lines.

---

## Q1: Can you serve HTTP on an already-terminated TLS connection?

**Answer: Yes, and HTTP/2 works automatically -- but you must understand the mechanism.**

### How Go's HTTP/2 works internally

When `http.Server.Serve()` accepts a connection, each connection is handled in `(*conn).serve()`. The critical code path (from `net/http/server.go` ~line 1924):

```go
if tlsConn, ok := c.rwc.(*tls.Conn); ok {
    if err := tlsConn.HandshakeContext(ctx); err != nil {
        return
    }
    c.tlsState = new(tls.ConnectionState)
    *c.tlsState = tlsConn.ConnectionState()

    if proto := c.tlsState.NegotiatedProtocol; validNextProto(proto) {
        if fn := c.server.TLSNextProto[proto]; fn != nil {
            h := initALPNRequest{ctx, tlsConn, serverHandler{c.server}}
            c.setState(c.rwc, StateActive, skipHooks)
            fn(c.server, tlsConn, h)
        }
        return
    }
}
// Falls through to HTTP/1.1 handling
```

This means:

1. The server type-asserts the connection to `*tls.Conn`
2. It calls `Handshake()` (which is a no-op if handshake already completed)
3. It checks `NegotiatedProtocol` from ALPN
4. If "h2" was negotiated, it dispatches to the registered HTTP/2 handler in `TLSNextProto`
5. Otherwise, it falls through to HTTP/1.1

### The integration path for our use case

We terminate TLS ourselves with `tls.Server(conn, tlsConfig)`, getting a `*tls.Conn`. We then feed this to `http.Server` via a one-shot `net.Listener`. The key requirements:

1. **`tls.Config.NextProtos` must include `"h2"` and `"http/1.1"`** -- this enables ALPN negotiation during our TLS termination
2. **`http2.ConfigureServer(&httpServer, nil)`** must be called -- this populates `httpServer.TLSNextProto["h2"]` with a handler that calls `http2.Server.ServeConn`
3. **`httpServer.TLSConfig` must be set** to the same `*tls.Config` used for TLS termination

When the `http.Server` receives our `*tls.Conn` via the listener, it type-asserts successfully, calls `Handshake()` (no-op since we already completed it), reads the `NegotiatedProtocol`, and dispatches accordingly.

### The one-shot listener pattern

Since `http.Server.Serve()` expects a `net.Listener`, but we have individual connections, we need a wrapper. This is an established Go pattern (~15 lines):

```go
type singleConnListener struct {
    conn    net.Conn
    once    sync.Once
    closeCh chan struct{}
}

func (l *singleConnListener) Accept() (net.Conn, error) {
    var c net.Conn
    l.once.Do(func() { c = l.conn })
    if c != nil {
        return c, nil
    }
    <-l.closeCh
    return nil, errors.New("listener closed")
}

func (l *singleConnListener) Close() error {
    close(l.closeCh)
    return nil
}

func (l *singleConnListener) Addr() net.Addr {
    return l.conn.LocalAddr()
}
```

### Alternative: Use `http2.Server.ServeConn` directly

For maximum control, skip `http.Server` entirely for HTTP/2 connections:

```go
tlsConn := tls.Server(rawConn, tlsConfig)
if err := tlsConn.Handshake(); err != nil {
    return err
}

state := tlsConn.ConnectionState()
if state.NegotiatedProtocol == "h2" {
    h2srv := &http2.Server{}
    h2srv.ServeConn(tlsConn, &http2.ServeConnOpts{
        Handler: myHandler,
    })
} else {
    // HTTP/1.1: use http.Server with one-shot listener
    // or manually read requests with http.ReadRequest
}
```

`http2.Server.ServeConn` explicitly supports `*tls.Conn` -- from the docs: *"If c has a ConnectionState method like a *tls.Conn, the ConnectionState is used to verify the TLS ciphersuite and to set the Request.TLS field in Handlers."*

### Gotchas

- **`Server.Serve()` calls `Handshake()` on `*tls.Conn`** -- this is safe if handshake is already done (it's a no-op), but means the connection must be a `*tls.Conn` (not a plain `net.Conn` wrapping a TLS stream)
- **`http2.ConfigureServer` must be called explicitly** when using `Server.Serve()` instead of `Server.ServeTLS()` -- `ServeTLS` calls it automatically, `Serve` does not
- **Per-connection `http.Server` instances** have overhead. A better pattern might be to use a single `http.Server` with a channel-based listener that accepts multiple intercepted connections

---

## Q2: Does httputil.ReverseProxy handle SSE streaming correctly?

**Answer: Yes, with automatic detection. No configuration needed for text/event-stream.**

### The built-in SSE detection

From `net/http/httputil/reverseproxy.go`, the `flushInterval` method:

```go
func (p *ReverseProxy) flushInterval(res *http.Response) time.Duration {
    resCT := res.Header.Get("Content-Type")

    // For Server-Sent Events responses, flush immediately.
    if baseCT, _, _ := mime.ParseMediaType(resCT); baseCT == "text/event-stream" {
        return -1 // negative means immediately
    }

    // Streaming response with unknown length: flush immediately.
    if res.ContentLength == -1 {
        return -1
    }

    return p.FlushInterval
}
```

This means:

1. **`text/event-stream`** responses are auto-detected and flushed immediately (even with `charset` parameters, since `mime.ParseMediaType` extracts the base type)
2. **`Content-Length: -1`** (chunked/unknown length) responses are also flushed immediately
3. **`FlushInterval: -1`** can be set explicitly on the proxy to force immediate flushing for all responses

### LLM API specifics

LLM APIs (OpenAI, Anthropic) return `Content-Type: text/event-stream` for streaming responses. The ReverseProxy will:
- Detect this Content-Type
- Set flush interval to -1 (immediate)
- Use `maxLatencyWriter` which flushes after every write
- Stream SSE events to the client without buffering

For non-streaming responses (e.g., non-streaming completions returning JSON), the response is a normal HTTP response and will be handled normally.

### Gotchas

- **FlushInterval default is 0** (no periodic flushing for non-SSE), which is fine -- SSE is auto-detected
- **Earlier Go versions** (pre-1.20 approximately) had a bug where `text/event-stream;charset=utf-8` was not detected. Current versions use `mime.ParseMediaType` and are correct
- **HTTP/2 multiplexing** means multiple SSE streams share a single TCP connection -- this works correctly because HTTP/2 has per-stream flow control

---

## Q3: Existing Go MITM proxy implementations

### google/martian

**Best reference for our use case.** Production-quality, used internally at Google.

- **Certificate generation:** ~40 lines of core cert generation in `mitm/mitm.go`
- **Certificate caching:** `sync.RWMutex`-protected `map[string]*tls.Certificate`, validates expiry before returning cached cert
- **Key type:** RSA-2048 for both CA and leaf certs
- **GetCertificate callback:** Registered via `tls.Config.GetCertificate`, extracts hostname from `ClientHelloInfo.ServerName`
- **HTTP/2:** Not clear from the source; may not handle HTTP/2 MITM

Source: https://github.com/google/martian/blob/master/mitm/mitm.go

### elazarl/goproxy

Most popular Go MITM proxy library.

- **Transparent proxy example:** Shows full transparent HTTPS MITM with cert generation
- **SNI handling:** Peeks ClientHello for SNI
- **HTTP/2:** Not supported. HTTP/1.1 only for MITM connections
- **Architecture:** Standard HTTP proxy (CONNECT-based), not designed for transparent interception at the TCP level

Source: https://github.com/elazarl/goproxy

### AdguardTeam/gomitmproxy

- **CertsStorage interface:** Pluggable cert caching with `Get`/`Set` methods; default is in-memory map
- **HTTP/2:** Not supported
- **Architecture:** HTTP proxy with MITM capability

Source: https://github.com/AdguardTeam/gomitmproxy

### Assessment

None of these libraries handle HTTP/2 MITM well. They all operate at the HTTP/1.1 level. For our use case (which requires HTTP/2 for Anthropic/OpenAI APIs), we need to build on the stdlib approach described in Q1. However, **Martian's certificate generation code** (~40 lines) is a useful reference.

---

## Q4: Dynamic certificate generation in Go

### The complete pattern

Certificate generation for MITM requires approximately **30-40 lines** of core logic:

```go
func generateCert(hostname string, caCert *x509.Certificate, caKey crypto.PrivateKey) (*tls.Certificate, error) {
    // Generate leaf key (~2 lines)
    leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
    if err != nil {
        return nil, err
    }

    // Serial number (~2 lines)
    serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
    if err != nil {
        return nil, err
    }

    // Certificate template (~15 lines)
    template := &x509.Certificate{
        SerialNumber: serialNumber,
        Subject:      pkix.Name{CommonName: hostname},
        NotBefore:    time.Now().Add(-1 * time.Hour),
        NotAfter:     time.Now().Add(24 * time.Hour),
        KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
        ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
        DNSNames:     []string{hostname},
    }

    // Sign with CA (~5 lines)
    certDER, err := x509.CreateCertificate(rand.Reader, template, caCert, &leafKey.PublicKey, caKey)
    if err != nil {
        return nil, err
    }

    return &tls.Certificate{
        Certificate: [][]byte{certDER, caCert.Raw},
        PrivateKey:  leafKey,
        Leaf:        template,
    }, nil
}
```

### Key design decisions

- **ECDSA P-256 over RSA-2048:** Faster key generation (sub-millisecond vs ~100ms), smaller certs, adequate security. For a proxy that generates many certs, this matters.
- **Short validity (24h):** Limits risk from stolen certs; no revocation infrastructure needed
- **NotBefore backdated 1 hour:** Prevents clock-skew rejection
- **Include CA cert in chain:** `Certificate: [][]byte{certDER, caCert.Raw}` ensures the client can verify the chain

### Caching

A simple `sync.Map` or `sync.RWMutex + map[string]*tls.Certificate` is sufficient. The inetaf/tcpproxy-style `GetCertificate` callback integrates naturally:

```go
type certCache struct {
    mu    sync.RWMutex
    certs map[string]*tls.Certificate
    ca    *x509.Certificate
    caKey crypto.PrivateKey
}

func (c *certCache) GetCertificate(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
    hostname := hello.ServerName

    c.mu.RLock()
    if cert, ok := c.certs[hostname]; ok {
        c.mu.RUnlock()
        return cert, nil
    }
    c.mu.RUnlock()

    cert, err := generateCert(hostname, c.ca, c.caKey)
    if err != nil {
        return nil, err
    }

    c.mu.Lock()
    c.certs[hostname] = cert
    c.mu.Unlock()

    return cert, nil
}
```

Total cert generation + caching: **~50 lines**.

### No external libraries needed

`crypto/x509`, `crypto/ecdsa`, `crypto/elliptic`, `crypto/rand` -- all stdlib.

---

## Q5: SNI peeking without consuming the connection

**Answer: This is a solved problem with multiple proven patterns.**

### Pattern 1: bufio.Reader.Peek (used by inetaf/tcpproxy)

This is the exact code already vendored in gvisor-tap-vsock at `vendor/github.com/inetaf/tcpproxy/sni.go`:

```go
func clientHelloServerName(br *bufio.Reader) (sni string) {
    const recordHeaderLen = 5
    hdr, err := br.Peek(recordHeaderLen)
    if err != nil {
        return ""
    }
    const recordTypeHandshake = 0x16
    if hdr[0] != recordTypeHandshake {
        return ""
    }
    recLen := int(hdr[3])<<8 | int(hdr[4])
    helloBytes, err := br.Peek(recordHeaderLen + recLen)
    if err != nil {
        return ""
    }
    tls.Server(sniSniffConn{r: bytes.NewReader(helloBytes)}, &tls.Config{
        GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
            sni = hello.ServerName
            return nil, nil
        },
    }).Handshake()
    return
}
```

After peeking, the buffered bytes are replayed automatically when the connection is wrapped in `tcpproxy.Conn`:

```go
type Conn struct {
    HostName string
    Peeked   []byte   // bytes already read, replayed by Read()
    net.Conn
}

func (c *Conn) Read(p []byte) (n int, err error) {
    if len(c.Peeked) > 0 {
        n = copy(p, c.Peeked)
        c.Peeked = c.Peeked[n:]
        if len(c.Peeked) == 0 {
            c.Peeked = nil
        }
        return n, nil
    }
    return c.Conn.Read(p)
}
```

### Pattern 2: io.TeeReader + io.MultiReader

From Andrew Ayer's SNI proxy:

```go
func peekClientHello(reader io.Reader) (*tls.ClientHelloInfo, io.Reader, error) {
    peekedBytes := new(bytes.Buffer)
    hello, err := readClientHello(io.TeeReader(reader, peekedBytes))
    if err != nil {
        return nil, nil, err
    }
    return hello, io.MultiReader(peekedBytes, reader), nil
}
```

Returns an `io.Reader` that first replays buffered bytes, then reads from the original connection.

### Which to use

**Pattern 1 (bufio.Reader.Peek)** is better for our case because:
- `inetaf/tcpproxy` is already a dependency of gvisor-tap-vsock
- The `tcpproxy.Conn` wrapper implements `net.Conn`, which `tls.Server()` requires
- The peeked bytes are replayed transparently

### Gotcha: Large ClientHellos

The `bufio.Reader` default buffer is 4096 bytes. TLS 1.3 ClientHellos with many extensions can exceed this. The inetaf/tcpproxy project has an [open issue](https://github.com/inetaf/tcpproxy/issues/40) about this. Mitigation: create the `bufio.Reader` with a larger buffer:

```go
br := bufio.NewReaderSize(conn, 16384) // 16KB should be more than enough
```

---

## Q6: Integration with gvisor-tap-vsock's TCP forwarder

### Current architecture

From `pkg/services/forwarder/tcp.go`:

```go
func TCP(s *stack.Stack, nat map[tcpip.Address]tcpip.Address, natLock *sync.Mutex, ec2MetadataAccess bool) *tcp.Forwarder {
    return tcp.NewForwarder(s, 0, 10, func(r *tcp.ForwarderRequest) {
        localAddress := r.ID().LocalAddress
        // ... NAT lookup ...

        outbound, err := net.Dial("tcp", net.JoinHostPort(localAddress.String(), fmt.Sprint(r.ID().LocalPort)))
        // ...

        var wq waiter.Queue
        ep, tcpErr := r.CreateEndpoint(&wq)
        r.Complete(false)
        // ...

        remote := tcpproxy.DialProxy{
            DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
                return outbound, nil
            },
        }
        remote.HandleConn(gonet.NewTCPConn(&wq, ep))
    })
}
```

The key insight: **`gonet.NewTCPConn(&wq, ep)` returns a `*gonet.TCPConn` which implements `net.Conn`**. This is the guest-side connection. The current code dials the real destination and proxies bytes bidirectionally.

### Integration point

We intercept at the forwarder callback level. Instead of blindly proxying, we:

1. Get the `net.Conn` from `gonet.NewTCPConn(&wq, ep)` (guest-side)
2. Check if `r.ID().LocalPort == 443` and the destination IP matches our target hosts
3. If yes: route to our MITM handler
4. If no: proxy normally (existing behavior)

```go
func TCPWithCredentialProxy(s *stack.Stack, nat map[tcpip.Address]tcpip.Address,
    natLock *sync.Mutex, interceptor *CredentialProxy) *tcp.Forwarder {

    return tcp.NewForwarder(s, 0, 10, func(r *tcp.ForwarderRequest) {
        localAddress := r.ID().LocalAddress
        localPort := r.ID().LocalPort

        // NAT translation (same as before)
        natLock.Lock()
        if replaced, ok := nat[localAddress]; ok {
            localAddress = replaced
        }
        natLock.Unlock()

        var wq waiter.Queue
        ep, tcpErr := r.CreateEndpoint(&wq)
        r.Complete(false)
        if tcpErr != nil {
            return
        }
        guestConn := gonet.NewTCPConn(&wq, ep)

        // Decision: intercept or passthrough
        if localPort == 443 && interceptor.ShouldIntercept(localAddress) {
            interceptor.HandleConn(guestConn, localAddress.String())
            return
        }

        // Passthrough: existing behavior
        outbound, err := net.Dial("tcp", net.JoinHostPort(localAddress.String(), fmt.Sprint(localPort)))
        if err != nil {
            guestConn.Close()
            return
        }
        proxy := tcpproxy.DialProxy{
            DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
                return outbound, nil
            },
        }
        proxy.HandleConn(guestConn)
    })
}
```

### Important detail: DNS resolution

The current forwarder uses the destination IP (after NAT) to dial. For our MITM proxy, we need the **hostname** (for cert generation and upstream SNI). We have two options:

1. **SNI peek:** Read the ClientHello from the guest connection to extract the target hostname. This is the cleanest approach and works regardless of DNS.
2. **Reverse DNS from IP:** Maintain a mapping from the DNS resolver. Since gvisor-tap-vsock already has a DNS server (`pkg/services/dns`), we could record A record responses.

**SNI peek is the correct approach** -- it's authoritative (it's what the client actually requested) and doesn't require coupling to the DNS subsystem.

---

## Complete Architecture

```
Guest VM                    Host (gvisor-tap-vsock)
---------                   ----------------------

curl https://api.openai.com/...
    |
    v
[TCP SYN to api.openai.com:443]
    |
    v
[gvisor TCP forwarder callback]
    |
    +-- port != 443? --> normal passthrough (net.Dial + proxy)
    |
    +-- port == 443
        |
        v
    [gonet.NewTCPConn: get net.Conn from guest]
        |
        v
    [bufio.Reader.Peek: read TLS ClientHello]
        |
        +-- SNI not in intercept list? --> passthrough to real server
        |
        +-- SNI matches (e.g., api.openai.com)
            |
            v
        [tls.Server(conn, &tls.Config{
            GetCertificate: certCache.GetCertificate,  // dynamic cert
            NextProtos: ["h2", "http/1.1"],             // enable ALPN
        })]
            |
            v
        [http.Server.Serve() OR http2.Server.ServeConn]
        [Handler: httputil.ReverseProxy{
            Director: func(req) {
                req.Header.Set("Authorization", "Bearer " + realAPIKey)
                req.URL.Host = originalHost
                req.URL.Scheme = "https"
            },
            FlushInterval: -1,  // immediate flush (SSE auto-detected anyway)
        }]
            |
            v
        [ReverseProxy dials real api.openai.com:443 over TLS]
        [Streams response back through the chain]
```

---

## Custom Code Inventory

### What the stdlib/libraries handle (zero custom code)

| Capability | Provided by |
|---|---|
| TCP connection from gvisor userspace stack | `gvisor.dev/gvisor/pkg/tcpip/adapters/gonet` |
| SNI ClientHello parsing | `inetaf/tcpproxy` (already vendored) |
| TLS termination with dynamic certs | `crypto/tls` (`tls.Server` + `GetCertificate`) |
| HTTP/1.1 request parsing & serving | `net/http` |
| HTTP/2 request parsing & serving | `golang.org/x/net/http2` (via `ConfigureServer` or `ServeConn`) |
| ALPN negotiation (h2 vs http/1.1) | `crypto/tls` (automatic via `NextProtos`) |
| Reverse proxying with header rewriting | `net/http/httputil.ReverseProxy` |
| SSE streaming (flush on text/event-stream) | `net/http/httputil.ReverseProxy` (automatic) |
| Hop-by-hop header removal | `net/http/httputil.ReverseProxy` (automatic) |
| Connection pooling to upstream | `net/http.Transport` (used by ReverseProxy) |
| Certificate signing | `crypto/x509.CreateCertificate` |
| ECDSA key generation | `crypto/ecdsa` + `crypto/elliptic` |

### What we write (~200-300 lines)

| Component | Lines | Description |
|---|---|---|
| Certificate generation | ~30 | `generateCert(hostname, caCert, caKey)` |
| Certificate cache | ~25 | `sync.RWMutex` + `map[string]*tls.Certificate` + `GetCertificate` callback |
| One-shot listener | ~15 | Wraps a single `net.Conn` as a `net.Listener` for `http.Server.Serve()` |
| MITM handler | ~50 | SNI peek -> TLS terminate -> dispatch to http.Server or http2.ServeConn |
| ReverseProxy director | ~15 | Token swap in Authorization header, URL fixup |
| Forwarder integration | ~40 | Modified TCP forwarder callback with intercept decision |
| Config / host list | ~20 | Which hosts to intercept, CA cert loading, API key management |
| **Total** | **~200** | |

### Dependencies (all already in gvisor-tap-vsock or stdlib)

- `gvisor.dev/gvisor/pkg/tcpip/adapters/gonet` (already vendored)
- `github.com/inetaf/tcpproxy` (already vendored -- provides SNI peek + Conn wrapper)
- `golang.org/x/net/http2` (standard extended library)
- `crypto/tls`, `crypto/x509`, `crypto/ecdsa`, `net/http`, `net/http/httputil` (stdlib)

### No external libraries needed

The entire MITM proxy can be built with Go's standard library, `golang.org/x/net/http2`, and libraries already vendored in gvisor-tap-vsock. No need for `elazarl/goproxy`, `google/martian`, or any other proxy framework.

---

## Risk Assessment

### Low risk

- **SSE streaming:** Proven to work. ReverseProxy auto-detects `text/event-stream` and flushes immediately. LLM APIs use standard SSE.
- **Certificate generation:** Well-understood stdlib path. ~30 lines of code, many reference implementations.
- **SNI peeking:** inetaf/tcpproxy has been doing this in production for years. Already vendored.

### Medium risk

- **HTTP/2 on pre-terminated TLS:** The mechanism works (proven by reading Go source), but requires careful setup: `NextProtos`, `ConfigureServer`, and correct `*tls.Conn` type assertions. A mistake here silently degrades to HTTP/1.1 (which still works, but is suboptimal).
- **Per-connection http.Server overhead:** Creating a new `http.Server` per intercepted connection has some overhead. Better to use a shared server with a channel-based listener, or dispatch directly to `http2.ServeConn` / manual HTTP/1.1 handling.

### Low risk (but verify)

- **Large ClientHellos:** Ensure `bufio.Reader` buffer is large enough (16KB). Default 4KB may be too small for TLS 1.3 with many extensions.
- **Connection lifecycle:** When the guest closes the connection, ensure cleanup propagates through the TLS layer and ReverseProxy. The ReverseProxy handles this, but test with long-lived SSE streams.

---

## Recommended Implementation Approach

### Phase 1: Minimal viable proxy (HTTP/1.1 only)

1. Modify gvisor-tap-vsock TCP forwarder to intercept port 443 connections
2. Peek SNI, generate cert, terminate TLS
3. Use `httputil.ReverseProxy` with token swap in Director
4. Test with `curl --cacert` against OpenAI API

### Phase 2: HTTP/2 support

1. Add `NextProtos: ["h2", "http/1.1"]` to TLS config
2. Add `http2.ConfigureServer` call
3. Check `NegotiatedProtocol` and dispatch accordingly
4. Test with HTTP/2-capable clients

### Phase 3: Production hardening

1. Certificate cache with TTL-based expiry
2. Graceful connection cleanup on proxy shutdown
3. Metrics/logging for intercepted requests
4. Error handling for upstream TLS failures

---

## Sources

- Go `net/http/server.go` source: https://go.dev/src/net/http/server.go
- Go `net/http/httputil/reverseproxy.go` source: https://go.dev/src/net/http/httputil/reverseproxy.go
- `golang.org/x/net/http2` package: https://pkg.go.dev/golang.org/x/net/http2
- `golang.org/x/net/http2` server source: https://github.com/golang/net/blob/master/http2/server.go
- `inetaf/tcpproxy` SNI implementation: https://github.com/inetaf/tcpproxy/blob/master/sni.go
- Go issue #14374 (Server.Serve + HTTP/2): https://github.com/golang/go/issues/14374
- Go issue #14619 (HTTP/2 on custom listener): https://github.com/golang/go/issues/14619
- Go issue #46602 (ServeTLS vs Serve for HTTP/2): https://github.com/golang/go/issues/46602
- Go issue #36673 (ServeConn proposal): https://github.com/golang/go/issues/36673
- Go issue #47359 (ReverseProxy SSE flush): https://github.com/golang/go/issues/47359
- Google Martian MITM: https://github.com/google/martian/blob/master/mitm/mitm.go
- elazarl/goproxy transparent example: https://github.com/elazarl/goproxy/tree/master/examples/goproxy-transparent
- Andrew Ayer's SNI proxy: https://www.agwa.name/blog/post/writing_an_sni_proxy_in_go
- MITM proxy in Go guide: https://agst.dev/posts/tls-http-proxy-go/
- Eli Bendersky's HTTPS proxy guide: https://eli.thegreenplace.net/2022/go-and-proxy-servers-part-2-https-proxies/
- Certificate generation gist: https://gist.github.com/shaneutt/5e1995295cff6721c89a71d13a71c251
- gvisor-tap-vsock TCP forwarder: `pkg/services/forwarder/tcp.go`
- gvisor-tap-vsock services wiring: `pkg/virtualnetwork/services.go`
