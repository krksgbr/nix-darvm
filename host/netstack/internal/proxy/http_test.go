package proxy

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"strconv"
	"sync/atomic"
	"testing"

	"github.com/unbody/darvm/netstack/internal/control"
)

// TestHTTPNoReplacement_PlaceholderPassesThrough verifies that for plain HTTP
// (not HTTPS) the proxy does NOT replace placeholders — the placeholder passes
// through as-is. This prevents credential leaks over cleartext.
func TestHTTPNoReplacement_PlaceholderPassesThrough(t *testing.T) {
	t.Parallel()

	secrets := []control.SecretRule{{
		Name:        "test-api-key",
		Hosts:       []string{"localhost"},
		Placeholder: "PLACEHOLDER_TOKEN",
		Value:       "real-secret-value",
	}}

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Placeholder should NOT be replaced for HTTP.
		auth := r.Header.Get("Authorization")
		if auth != "Bearer PLACEHOLDER_TOKEN" {
			t.Errorf("expected placeholder to pass through, got Authorization %q", auth)
		}

		w.WriteHeader(http.StatusOK)

		if _, err := w.Write([]byte("ok")); err != nil {
			t.Errorf("write response: %v", err)
		}
	}))
	t.Cleanup(upstream.Close)

	upHost, upPortStr, _ := net.SplitHostPort(upstream.Listener.Addr().String())
	upPort, _ := strconv.Atoi(upPortStr)

	interceptor := newTestInterceptor(t, secrets, nil)
	proxyAddr := startProxyListener(t, interceptor, "http", upHost, upPort)
	client := newProxyHTTPClient(t, proxyAddr)

	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "http://localhost/path", nil)
	req.Header.Set("Authorization", "Bearer PLACEHOLDER_TOKEN")

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}

	defer func() {
		if err := resp.Body.Close(); err != nil {
			t.Errorf("close response body: %v", err)
		}
	}()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", resp.StatusCode)
	}
}

// TestHTTPNonInterceptedHost_Unchanged verifies that requests to hosts without
// secret rules pass through unmodified — original headers preserved.
func TestHTTPNonInterceptedHost_Unchanged(t *testing.T) {
	t.Parallel()

	secrets := []control.SecretRule{{
		Name:        "other-secret",
		Hosts:       []string{"other.example.com"},
		Placeholder: "PLACEHOLDER",
		Value:       "secret-value",
	}}

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if auth := r.Header.Get("Authorization"); auth != "" {
			t.Errorf("expected no Authorization header, got %q", auth)
		}

		if custom := r.Header.Get("X-Custom"); custom != "preserved" {
			t.Errorf("expected X-Custom=preserved, got %q", custom)
		}

		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(upstream.Close)

	upHost, upPortStr, _ := net.SplitHostPort(upstream.Listener.Addr().String())
	upPort, _ := strconv.Atoi(upPortStr)

	interceptor := newTestInterceptor(t, secrets, nil)
	proxyAddr := startProxyListener(t, interceptor, "http", upHost, upPort)
	client := newProxyHTTPClient(t, proxyAddr)

	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "http://localhost/path", nil)
	req.Header.Set("X-Custom", "preserved")

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}

	defer func() {
		if err := resp.Body.Close(); err != nil {
			t.Errorf("close response body: %v", err)
		}
	}()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", resp.StatusCode)
	}
}

// TestHTTPKeepAlive verifies that multiple requests over a single kept-alive
// connection work and that the connection is actually reused.
func TestHTTPKeepAlive(t *testing.T) {
	t.Parallel()

	var reqCount atomic.Int32

	secrets := []control.SecretRule{{
		Name:        "ka-secret",
		Hosts:       []string{"localhost"},
		Placeholder: "KA_PLACEHOLDER",
		Value:       "ka-value",
	}}

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqCount.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(upstream.Close)

	upHost, upPortStr, _ := net.SplitHostPort(upstream.Listener.Addr().String())
	upPort, _ := strconv.Atoi(upPortStr)

	interceptor := newTestInterceptor(t, secrets, nil)
	proxyAddr := startProxyListener(t, interceptor, "http", upHost, upPort)
	client := newProxyHTTPClient(t, proxyAddr)

	// First request.
	req1, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "http://localhost/first", nil)

	resp1, err := client.Do(req1)
	if err != nil {
		t.Fatalf("first GET failed: %v", err)
	}

	if err := resp1.Body.Close(); err != nil {
		t.Fatalf("close first response body: %v", err)
	}

	// Second request — verify the connection is actually reused via httptrace.
	var reused bool

	trace := &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			reused = info.Reused
		},
	}
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, "http://localhost/second", nil)
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), trace))

	resp2, err := client.Do(req)
	if err != nil {
		t.Fatalf("second GET failed: %v", err)
	}

	if err := resp2.Body.Close(); err != nil {
		t.Fatalf("close second response body: %v", err)
	}

	if !reused {
		t.Fatal("second request did not reuse the keep-alive connection")
	}

	if reqCount.Load() != 2 {
		t.Fatalf("expected 2 requests at upstream, got %d", reqCount.Load())
	}
}
