package proxy

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/unbody/darvm/netstack/internal/control"
)

// upstreamTransport returns a transport that trusts the httptest TLS server's
// certificate and skips hostname verification. This is needed because
// rewriteRequest sets URL.Host = "localhost:<port>" but the httptest cert is
// for "example.com". InsecureSkipVerify only affects the proxy→upstream leg;
// the client→proxy leg still does full cert verification against the MITM CA.
func upstreamTransport(t *testing.T, upstream *httptest.Server) *http.Transport {
	t.Helper()

	baseTransport, ok := upstream.Client().Transport.(*http.Transport)
	if !ok {
		t.Fatalf("unexpected upstream transport type %T", upstream.Client().Transport)
	}
	tr := baseTransport.Clone()
	tr.TLSClientConfig.InsecureSkipVerify = true

	return tr
}

// TestHTTPSNoCA_PassesThroughWithoutMITM verifies that when no CA is
// configured (caPool == nil), HTTPS connections are passed through as raw TCP
// even for hosts that have secret rules.
func TestHTTPSNoCA_PassesThroughWithoutMITM(t *testing.T) {
	t.Parallel()

	secrets := []control.SecretRule{{
		Name:        "no-ca-secret",
		Hosts:       []string{"example.com"},
		Placeholder: "PLACEHOLDER",
		Value:       "secret-value",
	}}

	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// No replacement should occur — proxy can't MITM without a CA.
		if auth := r.Header.Get("Authorization"); auth != "" {
			t.Errorf("expected no Authorization header, got %q", auth)
		}

		w.WriteHeader(http.StatusOK)

		if _, err := w.Write([]byte("no-ca-passthrough")); err != nil {
			t.Errorf("write response: %v", err)
		}
	}))
	t.Cleanup(upstream.Close)

	upstreamCert := upstream.Certificate()
	upstreamRoots := x509.NewCertPool()
	upstreamRoots.AddCert(upstreamCert)

	upHost, upPortStr, _ := net.SplitHostPort(upstream.Listener.Addr().String())
	upPort, _ := strconv.Atoi(upPortStr)

	// caPool is nil — MITM is disabled.
	interceptor := newTestInterceptor(t, secrets, nil)
	proxyAddr := startProxyListener(t, interceptor, "https", upHost, upPort)

	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp", proxyAddr)
			},
			TLSClientConfig: &tls.Config{
				RootCAs:    upstreamRoots,
				ServerName: "example.com",
			},
		},
	}

	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://example.com/test", nil)

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}

	defer func() {
		if err := resp.Body.Close(); err != nil {
			t.Errorf("close response body: %v", err)
		}
	}()

	body, _ := io.ReadAll(resp.Body)
	if string(body) != "no-ca-passthrough" {
		t.Fatalf("expected body 'no-ca-passthrough', got %q", body)
	}

	// Verify we got the upstream's real cert — not a MITM leaf.
	if resp.TLS == nil || len(resp.TLS.PeerCertificates) == 0 {
		t.Fatal("expected TLS peer certificates")
	}

	if !resp.TLS.PeerCertificates[0].Equal(upstreamCert) {
		t.Fatal("peer certificate does not match upstream — unexpected MITM")
	}
}

// TestHTTPSIntercept_ReplacesPlaceholderInHeader exercises the full MITM flow:
// client → proxy (terminates with MITM cert) → upstream (test TLS server).
// The guest sets Authorization with a placeholder; the proxy replaces it.
func TestHTTPSIntercept_ReplacesPlaceholderInHeader(t *testing.T) {
	t.Parallel()

	caPool, mitmRoots := newTestCA(t)

	secrets := []control.SecretRule{{
		Name:        "https-secret",
		Hosts:       []string{"localhost"},
		Placeholder: "SANDBOX_CRED_myproj_apikey_abc123",
		Value:       "real-bearer-value",
	}}

	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if auth != "Bearer real-bearer-value" {
			t.Errorf("expected Authorization 'Bearer real-bearer-value', got %q", auth)
		}

		w.WriteHeader(http.StatusOK)

		if _, err := w.Write([]byte("mitm-ok")); err != nil {
			t.Errorf("write response: %v", err)
		}
	}))
	t.Cleanup(upstream.Close)

	upHost, upPortStr, _ := net.SplitHostPort(upstream.Listener.Addr().String())
	upPort, _ := strconv.Atoi(upPortStr)

	interceptor := newTestInterceptor(t, secrets, caPool)
	interceptor.proxy.Transport = upstreamTransport(t, upstream)

	proxyAddr := startProxyListener(t, interceptor, "https", upHost, upPort)
	client := newProxyHTTPSClient(t, proxyAddr, mitmRoots, false)

	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://localhost/test", nil)
	req.Header.Set("Authorization", "Bearer SANDBOX_CRED_myproj_apikey_abc123")

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}

	defer func() {
		if err := resp.Body.Close(); err != nil {
			t.Errorf("close response body: %v", err)
		}
	}()

	body, _ := io.ReadAll(resp.Body)
	if string(body) != "mitm-ok" {
		t.Fatalf("expected body 'mitm-ok', got %q", body)
	}
}

// TestHTTPSIntercept_HTTP2Negotiated verifies that the MITM TLS connection
// negotiates HTTP/2 via ALPN (regression test for the HTTP/2 code path).
func TestHTTPSIntercept_HTTP2Negotiated(t *testing.T) {
	t.Parallel()

	caPool, mitmRoots := newTestCA(t)

	secrets := []control.SecretRule{{
		Name:        "h2-secret",
		Hosts:       []string{"localhost"},
		Placeholder: "H2_PLACEHOLDER",
		Value:       "h2-value",
	}}

	upstream := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	upstream.EnableHTTP2 = true
	upstream.StartTLS()
	t.Cleanup(upstream.Close)

	upHost, upPortStr, _ := net.SplitHostPort(upstream.Listener.Addr().String())
	upPort, _ := strconv.Atoi(upPortStr)

	interceptor := newTestInterceptor(t, secrets, caPool)
	interceptor.proxy.Transport = upstreamTransport(t, upstream)

	proxyAddr := startProxyListener(t, interceptor, "https", upHost, upPort)
	client := newProxyHTTPSClient(t, proxyAddr, mitmRoots, true)

	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://localhost/h2test", nil)

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}

	defer func() {
		if err := resp.Body.Close(); err != nil {
			t.Errorf("close response body: %v", err)
		}
	}()

	if resp.ProtoMajor != 2 {
		t.Fatalf("expected HTTP/2, got HTTP/%d.%d", resp.ProtoMajor, resp.ProtoMinor)
	}
}

// TestHTTPSPassthrough_PreservesUpstreamCert verifies that non-intercepted
// hosts get pure TCP passthrough — the client sees the upstream's real TLS
// certificate, not a MITM-generated one.
func TestHTTPSPassthrough_PreservesUpstreamCert(t *testing.T) {
	t.Parallel()

	caPool, _ := newTestCA(t)

	// No secrets for "localhost" — the host is not intercepted.
	secrets := []control.SecretRule{{
		Name:        "other-host-secret",
		Hosts:       []string{"other.example.com"},
		Placeholder: "OTHER_PLACEHOLDER",
		Value:       "other-value",
	}}

	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)

		if _, err := w.Write([]byte("passthrough-ok")); err != nil {
			t.Errorf("write response: %v", err)
		}
	}))
	t.Cleanup(upstream.Close)

	// Extract the upstream's certificate for client trust.
	upstreamCert := upstream.Certificate()
	upstreamRoots := x509.NewCertPool()
	upstreamRoots.AddCert(upstreamCert)

	upHost, upPortStr, _ := net.SplitHostPort(upstream.Listener.Addr().String())
	upPort, _ := strconv.Atoi(upPortStr)

	interceptor := newTestInterceptor(t, secrets, caPool)
	proxyAddr := startProxyListener(t, interceptor, "https", upHost, upPort)

	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp", proxyAddr)
			},
			TLSClientConfig: &tls.Config{
				RootCAs:    upstreamRoots,
				ServerName: "example.com",
			},
		},
	}

	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://example.com/passthrough", nil)

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}

	defer func() {
		if err := resp.Body.Close(); err != nil {
			t.Errorf("close response body: %v", err)
		}
	}()

	body, _ := io.ReadAll(resp.Body)
	if string(body) != "passthrough-ok" {
		t.Fatalf("expected body 'passthrough-ok', got %q", body)
	}

	if resp.TLS == nil || len(resp.TLS.PeerCertificates) == 0 {
		t.Fatal("expected TLS info with peer certificates")
	}

	if !resp.TLS.PeerCertificates[0].Equal(upstreamCert) {
		t.Fatal("peer certificate does not match upstream certificate — MITM may have occurred")
	}
}

// TestHTTPSNoSNI_FallsBackToPassthrough verifies that when the proxy cannot
// extract an SNI, traffic is passed through as-is.
func TestHTTPSNoSNI_FallsBackToPassthrough(t *testing.T) {
	t.Parallel()

	caPool, _ := newTestCA(t)

	secrets := []control.SecretRule{{
		Name:        "sni-secret",
		Hosts:       []string{"localhost"},
		Placeholder: "SNI_PLACEHOLDER",
		Value:       "sni-value",
	}}

	// Start a raw TCP echo server as upstream.
	echoLn, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen echo: %v", err)
	}

	cleanupClose(t, "echo listener", echoLn)

	go func() {
		for {
			conn, err := echoLn.Accept()
			if err != nil {
				return
			}

			go func(c net.Conn) {
				defer func() {
					if err := c.Close(); err != nil {
						t.Errorf("close echo conn: %v", err)
					}
				}()

				if _, err := io.Copy(c, c); err != nil {
					t.Errorf("echo copy: %v", err)
				}
			}(conn)
		}
	}()

	echoHost, echoPortStr, _ := net.SplitHostPort(echoLn.Addr().String())
	echoPort, _ := strconv.Atoi(echoPortStr)

	interceptor := newTestInterceptor(t, secrets, caPool)
	proxyAddr := startProxyListener(t, interceptor, "https", echoHost, echoPort)

	// Connect with raw TCP (no TLS) — proxy sees no ClientHello, no SNI.
	conn, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(context.Background(), "tcp", proxyAddr)
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}

	defer func() {
		if err := conn.Close(); err != nil {
			t.Errorf("close proxy conn: %v", err)
		}
	}()

	msg := "hello-no-sni\n"

	_, err = conn.Write([]byte(msg))
	if err != nil {
		t.Fatalf("write: %v", err)
	}

	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}

	buf := make([]byte, len(msg))

	_, err = io.ReadFull(conn, buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	if string(buf) != msg {
		t.Fatalf("expected echo %q, got %q", msg, string(buf))
	}
}

// TestHTTPSIntercept_SSEStreaming verifies that Server-Sent Events are flushed
// progressively through the proxy (FlushInterval: -1 behavior).
func TestHTTPSIntercept_SSEStreaming(t *testing.T) {
	t.Parallel()

	caPool, mitmRoots := newTestCA(t)

	secrets := []control.SecretRule{{
		Name:        "sse-secret",
		Hosts:       []string{"localhost"},
		Placeholder: "SSE_PLACEHOLDER",
		Value:       "sse-value",
	}}

	events := []string{"event-1", "event-2", "event-3"}

	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Error("upstream: ResponseWriter does not implement Flusher")

			return
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusOK)

		for _, ev := range events {
			if _, err := fmt.Fprintf(w, "data: %s\n\n", ev); err != nil {
				t.Errorf("write sse event: %v", err)
			}

			flusher.Flush()
			time.Sleep(50 * time.Millisecond)
		}
	}))
	t.Cleanup(upstream.Close)

	upHost, upPortStr, _ := net.SplitHostPort(upstream.Listener.Addr().String())
	upPort, _ := strconv.Atoi(upPortStr)

	interceptor := newTestInterceptor(t, secrets, caPool)
	interceptor.proxy.Transport = upstreamTransport(t, upstream)

	proxyAddr := startProxyListener(t, interceptor, "https", upHost, upPort)
	client := newProxyHTTPSClient(t, proxyAddr, mitmRoots, false)

	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://localhost/sse", nil)

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}

	defer func() {
		if err := resp.Body.Close(); err != nil {
			t.Errorf("close response body: %v", err)
		}
	}()

	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("expected Content-Type text/event-stream, got %q", ct)
	}

	scanner := bufio.NewScanner(resp.Body)

	var (
		received []string
		lastTime time.Time
	)

	progressive := true

	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}

		now := time.Now()

		received = append(received, strings.TrimPrefix(line, "data: "))

		if !lastTime.IsZero() && now.Sub(lastTime) < 10*time.Millisecond {
			progressive = false
		}

		lastTime = now
	}

	if err := scanner.Err(); err != nil {
		t.Fatalf("scanner error: %v", err)
	}

	if len(received) != len(events) {
		t.Fatalf("expected %d events, got %d: %v", len(events), len(received), received)
	}

	for i, ev := range events {
		if received[i] != ev {
			t.Errorf("event %d: expected %q, got %q", i, ev, received[i])
		}
	}

	if !progressive {
		t.Error("SSE events were not delivered progressively — possible buffering issue")
	}
}

// tlsClientHelloBytes generates a real TLS ClientHello by performing a
// handshake on a pipe. Returns the raw bytes written by the client.
func tlsClientHelloBytes(t *testing.T, serverName string) []byte {
	t.Helper()

	clientConn, serverConn := net.Pipe()
	cleanupClose(t, "client conn", clientConn)
	cleanupClose(t, "server conn", serverConn)

	var (
		clientHello []byte
		mu          sync.Mutex
	)

	done := make(chan struct{})

	go func() {
		defer close(done)

		buf := make([]byte, 16384)
		n, _ := serverConn.Read(buf)

		mu.Lock()
		clientHello = make([]byte, n)
		copy(clientHello, buf[:n])
		mu.Unlock()

		if err := serverConn.Close(); err != nil {
			t.Errorf("close server conn: %v", err)
		}
	}()

	tlsClient := tls.Client(clientConn, &tls.Config{
		ServerName:         serverName,
		InsecureSkipVerify: true,
	})
	_ = tlsClient.HandshakeContext(context.Background()) // expected to fail; we only need the ClientHello bytes

	if err := clientConn.Close(); err != nil {
		t.Fatalf("close client conn: %v", err)
	}

	<-done

	mu.Lock()
	defer mu.Unlock()

	return clientHello
}
