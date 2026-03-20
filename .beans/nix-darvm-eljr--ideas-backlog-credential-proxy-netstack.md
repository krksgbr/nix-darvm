---
# nix-darvm-eljr
title: Ideas backlog — credential proxy & netstack
status: todo
type: task
created_at: 2026-03-20T13:41:45Z
updated_at: 2026-03-20T13:41:45Z
---

Meta-bean tracking unspecified ideas that need more thought before becoming plans. Each item has a real-world motivation — why a user or developer would care.

## Ideas

### Integration test harness for the proxy

Zero unit/integration tests exist for the proxy code. Every change requires a full manual e2e cycle: start VM, curl endpoints, eyeball output. This is slow (~2 min turnaround) and fragile — the HTTP/2 regression we caught during the stdlib refactor (closeNotifyConn hiding `*tls.Conn`) would have been caught instantly by an automated test with a real HTTP/2 client.

**Who cares:** Developer. Faster feedback loop, fewer regressions slipping through manual testing.

### Wildcard host matching

Host matching is exact-only (`"api.anthropic.com"`). Users with services spanning many subdomains (e.g. `*.amazonaws.com` for S3, `*.openai.com`) must list every subdomain individually. Easy to miss one, and the config becomes verbose.

**Who cares:** User. Less config boilerplate, fewer "why isn't my credential being injected?" moments.

### SSL_CERT_FILE env var injection

The MITM CA is installed in the system trust store, but some tools (older Python, custom curl builds, certain Node versions) ignore it and require `SSL_CERT_FILE` or `NODE_EXTRA_CA_CERTS` pointing at the CA cert file. Without this, credential injection silently fails for those tools — the TLS handshake fails before the proxy ever sees the request.

**Who cares:** User. Mysterious TLS errors in specific tools with no obvious connection to the credential proxy.

### Structured metrics / observability

No visibility into proxy behavior at runtime. Can't tell how many requests were intercepted vs passed through, cert cache hit rate, upstream connection failures, or latency overhead. Debugging requires adding ad-hoc `log.Printf` and rebuilding.

**Who cares:** Developer (debugging) and eventually user (understanding what the proxy is doing with their traffic).
