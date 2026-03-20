---
# nix-darvm-8zgv
title: Integration test harness for credential proxy
status: completed
type: task
created_at: 2026-03-20T13:55:37Z
updated_at: 2026-03-20T13:55:37Z
---

Add integration tests for the proxy layer (host/netstack/internal/proxy/).
Currently zero tests exist — every change requires full VM + manual curl (~2 min).

## Motivation

During the stdlib refactor, wrapping `*tls.Conn` in `closeNotifyConn` hid the
type from `http.Server`'s HTTP/2 detection. ALPN negotiated h2 but the server
spoke HTTP/1.1. This passed manual testing (curl -sv showed headers) but broke
response bodies. An automated test asserting `resp.ProtoMajor == 2` would have
caught it instantly.

## Design (converged with Codex over 3 review rounds)

### Testing boundary

Test `HandleHTTP` and `HandleHTTPS` directly — the proxy entrypoints. This
covers SNI extraction, MITM TLS, ALPN, credential injection, keep-alive,
streaming, and passthrough. Avoids the slow path: gVisor stack, Ethernet
frames, VM boot, DNS.

### No production code changes

Tests live in package `proxy` (same package). Can set
`interceptor.proxy.Transport` directly to make the ReverseProxy trust test
upstream certs. No seams, interfaces, or dependency injection needed.

### Real loopback listeners, not net.Pipe

`net.Pipe` is fine for focused unit tests (`peekSNI`, cert cache), but
integration tests use real TCP on `127.0.0.1:0`. Reasons:
- Half-close semantics matter for passthrough (`io.Copy` relay)
- `http.Server` and `http.Transport` keep-alive behavior is more realistic
- HTTP/2 ALPN detection depends on the accepted conn's dynamic type
- Streaming/SSE flush behavior differs on real sockets

### Routing intercepted traffic to test upstreams

Use `localhost` as the intercepted hostname in test secrets. The proxy's
`rewriteRequest` sets `URL.Host = localhost:<dstPort>`, so the ReverseProxy
dials the test upstream naturally. No DNS tricks needed.

For passthrough tests, pass the test server's address as `dstIP`/`dstPort`
to `HandleHTTPS` — `tcpPassthrough` dials it directly.

### Two TLS trust models

- **Intercepted tests**: client trusts MITM CA only
- **Passthrough tests**: client trusts upstream test cert only, does NOT
  trust MITM CA. If the request succeeds, the proxy definitely didn't MITM.

### Composable helpers over monolithic harness

Prefer small functions over a big `proxyHarness` struct:

```go
// harness_test.go
func newTestCA(t *testing.T) (*CAPool, *x509.CertPool)
func newTestInterceptor(t *testing.T, secrets []control.SecretRule, caPool *CAPool) *Interceptor
func startProxyListener(t *testing.T, interceptor *Interceptor, mode string, dstIP string, dstPort int) (addr string)
func newProxyHTTPClient(t *testing.T, proxyAddr string) *http.Client
func newProxyHTTPSClient(t *testing.T, proxyAddr string, roots *x509.CertPool, forceH2 bool) *http.Client
```

Each test creates the upstream it needs with `httptest`. Topology stays
local to the test.

### HTTPS MITM test wiring

Two TLS sessions: client↔proxy (MITM cert) and proxy↔upstream (test cert).

1. `newTestCA(t)` → `caPool` + `mitmRoots` (client trust pool)
2. `httptest.NewTLSServer(handler)` → upstream with its own cert
3. `NewInterceptor(secrets, caPool)` → interceptor
4. Set `interceptor.proxy.Transport` to upstream's client transport (trusts upstream cert)
5. `startProxyListener(t, interceptor, "https", "127.0.0.1", upstreamPort)`
6. Client with `DialContext` → proxy addr, `RootCAs` → mitmRoots, `ForceAttemptHTTP2: true`

### HTTP/2 client setup

Standard `http.Client` disables HTTP/2 when `DialContext` or `TLSClientConfig`
are customized. Fix: set `ForceAttemptHTTP2: true` on the transport. No need
for `http2.ConfigureTransport`.

## Test plan

### P0 — catch real regressions

- [ ] `TestHTTPIntercept_ReplacesPlaceholderAndInjectsBearer`
- [ ] `TestHTTPNonInterceptedHost_Unchanged`
- [ ] `TestHTTPSIntercept_MITMAndInjectsCredentials`
- [ ] `TestHTTPSIntercept_HTTP2Negotiated` — assert `resp.ProtoMajor == 2`
- [ ] `TestHTTPSPassthrough_PreservesUpstreamCert` — client trusts upstream only
- [ ] `TestHTTPSNoSNI_FallsBackToPassthrough`

### P1 — connection lifecycle and streaming

- [ ] `TestHTTPIntercept_KeepAlive` — two requests on one connection
- [ ] `TestHTTPSIntercept_SSEStreaming` — progressive flush with `FlushInterval: -1`
- [ ] `TestPeekSNI_ValidClientHello` — unit test with `net.Pipe`
- [ ] `TestPeekSNI_GarbageInput` — returns empty, no panic
- [ ] `TestCAPool_CachesAndExpires` — same hostname returns cached cert, expired cert regenerated

### P2 — injection modes and edge cases

- [ ] `TestInject_Bearer_Basic_Header` — all three injection types
- [ ] `TestHostNormalization` — uppercase, trailing dot, host:port
- [ ] `TestPlaceholder_QueryParamsOnly` — body untouched
- [ ] `TestCertCache_RefreshOnExpiry`

## File layout

```
host/netstack/internal/proxy/
  harness_test.go        — helper functions
  http_test.go           — HTTP intercept, non-intercepted, keep-alive, SSE
  https_test.go          — MITM, h2 regression, passthrough, no-SNI
  tls_test.go            — peekSNI, cert generation, cache
```
