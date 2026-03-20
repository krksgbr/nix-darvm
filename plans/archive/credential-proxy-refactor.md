# Credential Proxy Refactor: Align with Recommended Architecture

## Background

The credential proxy works end-to-end for HTTP credential injection and HTTPS
passthrough. However, the interception layer was built with manual HTTP handling
instead of leveraging Go's stdlib proxy infrastructure. An independent research
evaluation confirmed that gvisor-tap-vsock was the right stack choice, and
produced a detailed implementation spec
(`docs/research/gvisor-tap-vsock-stack/implementation-stack.md`) recommending
`httputil.ReverseProxy`, `net/http.Server` with HTTP/2 via ALPN, and vendored
`inetaf/tcpproxy` for SNI extraction.

Two independent reviews (Claude and Codex) compared the current implementation
against the recommended architecture and converged on the same gaps and
priorities.

## Goals

- Replace hand-rolled HTTP proxying with `httputil.ReverseProxy`
- Replace hand-rolled SNI parsing with vendored `inetaf/tcpproxy`
- Add HTTP/2 support via `net/http.Server` + ALPN
- Switch from RSA-2048 to ECDSA-P256 for cert generation
- Fix identified bugs (SNI failure mode, keep-alive, streaming)
- Preserve existing capabilities the recommendation didn't account for
  (multi-project reload, rich injection model, port 80 interception,
  load-or-generate CA)

## What NOT to change

These are things the current implementation does better than the recommendation.
Preserve them through the refactor:

- **`replaceSecrets` injection model** — supports bearer, basic, custom header
  injection, plus placeholder substitution across all headers and query params.
  The recommendation's `Director` func is narrower. Port this logic into the
  `Director`/`Rewrite` callback on `ReverseProxy`.
- **Multi-project secret aggregation** — `control.go`'s `load`/`unload`/
  `mergedSecrets` and the control socket protocol. Untouched by this refactor.
- **Secret sourcing separation** — host resolves secrets, sidecar receives
  resolved values via control socket. Cleaner than the recommendation's
  "in-proxy credential store". Keep as-is.
- **Port 80 interception** — recommendation focuses on HTTPS. Keep HTTP
  interception path, but route it through `httputil.ReverseProxy` too.
- **Load-or-generate CA** — `NewCAPool` (external PEM) and `GenerateCA`
  (ephemeral). Keep both paths, update both for ECDSA.

## Implementation Steps

### Step 1: Replace SNI extraction with `inetaf/tcpproxy`

**Files:** `proxy/http.go`

**What to do:**
- Delete `peekClientHelloSNI`, `extractSNI`, `parseSNIExtension`,
  `prefixConn` (~135 lines)
- Import `inetaf/tcpproxy` (already vendored in gvisor-tap-vsock)
- Use `tcpproxy`'s `clientHelloServerName` with a `bufio.ReaderSize(conn, 16384)`
  for the SNI peek
- Use `tcpproxy.Conn` wrapper to replay peeked bytes (replaces `prefixConn`)

**Bug fix (from Codex review):** When SNI parsing fails, fall back to blind TCP
passthrough instead of dropping the connection. Current code does
`log.Printf(...); return` which kills the connection silently.

**Bug fix:** Handle no-SNI case explicitly. If `serverName` is empty after
peek, fall through to passthrough — don't attempt MITM with an IP-based cert.

**Estimated delta:** -135 lines, +20 lines

### Step 2: Switch to ECDSA-P256 certs

**Files:** `proxy/tls.go`

**What to do:**
- Change `CAPool.caKey` type from `*rsa.PrivateKey` to `crypto.Signer`
  (interface satisfied by both RSA and ECDSA keys)
- `GenerateCA`: replace `rsa.GenerateKey(rand.Reader, 2048)` with
  `ecdsa.GenerateKey(elliptic.P256(), rand.Reader)`
- `generateLeafCert`: same RSA→ECDSA swap
- `NewCAPool`: replace `x509.ParsePKCS1PrivateKey` with
  `x509.ParsePKCS8PrivateKey` (handles both RSA and ECDSA)
- Change leaf cert validity from 1 year to 24 hours
- Change `NotBefore` backdating from 5 minutes to 1 hour (clock skew margin)
- Keep CA validity at 1 year (CA lifetime = VM lifetime)

**Bug fix (from Codex review):** `NewCAPool` only parses PKCS#1 RSA keys. With
ECDSA, PEM-encoded keys use PKCS#8 or SEC1 encoding. Using
`x509.ParsePKCS8PrivateKey` handles all key types.

**Improvement:** Bound the cert cache. Replace `sync.Map` with a
`sync.RWMutex` + `map[string]*tls.Certificate` that checks cert expiry before
returning cached entries. Expired certs are regenerated on next request.

**Estimated delta:** ~0 net (type changes, same structure)

### Step 3: Introduce `net/http.Server` + `httputil.ReverseProxy`

**Files:** `proxy/http.go` (major rewrite of interception paths)

This is the largest step. It replaces the manual `ReadRequest`/`Write`/
`ReadResponse` loop with stdlib infrastructure.

**What to do:**

3a. Create a shared `httputil.ReverseProxy` instance on `Interceptor`:

```go
type Interceptor struct {
    mu        sync.RWMutex
    secrets   []control.SecretRule
    hostIndex map[string][]control.SecretRule
    caPool    *CAPool
    proxy     *httputil.ReverseProxy  // new
}
```

Configure the proxy:
- `Rewrite` callback: copy `replaceSecrets` logic here. Set
  `req.URL.Host`, `req.URL.Scheme = "https"`, then do placeholder
  substitution and inject-rule application.
- `FlushInterval: -1` (immediate flush for all responses — SSE auto-detected
  by `ReverseProxy` anyway, but this ensures no buffering surprises)
- `Transport`: a `*http.Transport` with reasonable defaults. This gives us
  connection pooling and upstream HTTP/2 for free.

3b. Create a one-shot `net.Listener` adapter (~15 lines):

```go
type singleConnListener struct {
    conn    net.Conn
    once    sync.Once
    closeCh chan struct{}
}
```

This wraps a single `net.Conn` (the guest's TLS-terminated connection) as a
`net.Listener` so it can be fed to `http.Server.Serve()`.

3c. Rewrite `HandleHTTPS` for intercepted hosts:

```
1. Peek SNI (step 1)
2. If not intercepted → tcpPassthroughWithPeeked (unchanged)
3. If intercepted:
   a. Wrap peeked bytes + conn into tcpproxy.Conn
   b. tls.Server(conn, &tls.Config{
        GetCertificate: caPool.GetCertificate,
        NextProtos: []string{"h2", "http/1.1"},
      })
   c. Handshake
   d. Create http.Server{Handler: interceptor.proxy}
   e. Call http2.ConfigureServer(&httpServer, nil)
   f. httpServer.Serve(singleConnListener{conn: tlsConn})
```

`net/http.Server` handles:
- HTTP/1.1 parsing and keep-alive
- HTTP/2 dispatch (automatic via ALPN + `ConfigureServer`)
- Request routing to our `ReverseProxy` handler

`httputil.ReverseProxy` handles:
- Upstream dialing + TLS + connection pooling
- Hop-by-hop header stripping
- SSE flush detection (`text/event-stream` → immediate flush)
- Chunked encoding, trailers
- Response streaming
- Cancellation propagation

3d. Rewrite `HandleHTTP` similarly:

For port 80, wrap the guest `net.Conn` in an `http.Server` with the same
`ReverseProxy` handler. No TLS termination needed — just
`httpServer.Serve(singleConnListener{conn: guestConn})`.

For non-intercepted hosts on port 80, the `Rewrite` callback can check
`req.Host` against the host index and pass through unmodified if no rules
match (set `req.URL.Host` to the original destination).

3e. Delete manual HTTP handling code:

- `forwardUnmodified` (~30 lines)
- `tcpPassthrough` / `tcpPassthroughWithPeeked` — keep these for non-intercepted
  HTTPS, but the HTTP versions go away
- `writeHTTPError` (~5 lines) — `ReverseProxy` handles error responses
- `writeResponse` (~7 lines)
- `isStreamingResponse` (~15 lines)
- `writeResponseHeadersAndStreamBody` (~35 lines)
- Manual request/response loop in `HandleHTTPS` (~35 lines)
- Manual request/response loop in `HandleHTTP` (~65 lines)

**Bug fixes absorbed by this step:**

- **Keep-alive broken for non-intercepted HTTP** (Codex finding):
  `forwardUnmodified` handled one request then returned. `http.Server` handles
  keep-alive correctly.
- **Streaming detection too broad** (Codex finding): treating all chunked
  responses as streaming broke connection reuse. `ReverseProxy` handles chunked
  encoding correctly without heuristics.
- **Hop-by-hop headers not stripped**: `ReverseProxy` does this automatically.
- **No connection pooling**: `http.Transport` pools upstream connections.
- **No upstream HTTP/2**: `http.Transport` negotiates HTTP/2 automatically.

**Estimated delta:** -250 lines, +80 lines

### Step 4: Cleanup

**Files:** `proxy/http.go`, `proxy/tls.go`, `stack/stack.go`

- Delete dead code: `EphemeralCA.swift` on the host side (already marked for
  deletion in `plans/credential-proxy.md`)
- Delete `handleUDPPacket` in `stack.go` (dead code, noted in credential-proxy
  plan)
- Remove unused imports
- Normalize host matching: lowercase hosts before indexing in `UpdateSecrets`
  and `secretsForHost`. Strip trailing dots.

### Step 5: Verify

**Manual verification:**

- `curl http://api.example.com` with placeholder → credential injected (HTTP)
- `curl https://api.anthropic.com` with placeholder → credential injected (HTTPS)
- `curl https://github.com` (non-intercepted) → passthrough, no MITM
- Streaming SSE response from Anthropic API → streams without buffering
- HTTP/2 client (`curl --http2`) → negotiates h2, request succeeds
- Multi-project reload via control socket → secrets update atomically
- Kill sidecar → guest networking dies (fail-closed preserved)
- Malformed ClientHello → falls back to TCP passthrough (not dropped)

**Future (not this PR):**

- Integration test harness with real HTTP/2 clients
- Structured metrics (intercept counts, cache hits, upstream failures)
- Wildcard host matching
- `SSL_CERT_FILE` environment variable for tools that ignore system trust store

## Sequencing

Steps 1 and 2 are independent of each other and can be done in either order.
Step 3 depends on step 1 (needs `tcpproxy.Conn` for the SNI peek).
Step 4 can happen any time after step 3.

```
Step 1 (SNI)  ──┐
                 ├──→ Step 3 (http.Server + ReverseProxy) ──→ Step 4 (cleanup) ──→ Step 5 (verify)
Step 2 (ECDSA) ─┘
```

## Risk

The main risk is step 3 — it's a structural rewrite of the interception path.
The `http.Server` + one-shot listener pattern is well-documented in Go but we
haven't used it before. The mitigation is that the existing tests (manual
end-to-end with `curl`) cover the critical paths, and we can land steps 1 and 2
first to build confidence before the larger change.

HTTP/2 through a one-shot listener + pre-terminated `*tls.Conn` requires
careful setup (`NextProtos`, `ConfigureServer`, correct type assertions). The
`go-stdlib-mitm-feasibility.md` research doc covers the exact mechanism and
gotchas. A mistake here silently degrades to HTTP/1.1, which still works.
