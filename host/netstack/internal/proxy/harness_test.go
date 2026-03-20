package proxy

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/unbody/darvm/netstack/internal/control"
)

// newTestCA generates a fresh ECDSA CA and returns both the CAPool (for the
// interceptor) and an x509.CertPool (for client trust).
func newTestCA(t *testing.T) (*CAPool, *x509.CertPool) {
	t.Helper()
	caPool, certPEM, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM([]byte(certPEM)) {
		t.Fatal("failed to add CA cert to root pool")
	}
	return caPool, roots
}

// newTestInterceptor creates an Interceptor with the given secrets and CA.
// The caller is responsible for setting interceptor.proxy.Transport if the
// upstream uses TLS (so the ReverseProxy trusts the test server's cert).
func newTestInterceptor(t *testing.T, secrets []control.SecretRule, caPool *CAPool) *Interceptor {
	t.Helper()
	return NewInterceptor(secrets, caPool)
}

// startProxyListener starts a TCP listener on 127.0.0.1:0 and dispatches
// accepted connections to the interceptor's HandleHTTP or HandleHTTPS.
// mode must be "http" or "https". Returns the listener address ("host:port").
func startProxyListener(t *testing.T, interceptor *Interceptor, mode string, dstIP string, dstPort int) string {
	t.Helper()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return // listener closed
			}
			switch mode {
			case "http":
				go interceptor.HandleHTTP(conn, dstIP, dstPort)
			case "https":
				go interceptor.HandleHTTPS(conn, dstIP, dstPort)
			}
		}
	}()

	return ln.Addr().String()
}

// newProxyHTTPClient returns an HTTP client whose DialContext always connects
// to proxyAddr, regardless of the requested host.
func newProxyHTTPClient(t *testing.T, proxyAddr string) *http.Client {
	t.Helper()
	return &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp", proxyAddr)
			},
		},
	}
}

// newProxyHTTPSClient returns an HTTPS client that dials proxyAddr for every
// connection and trusts the given root CAs. When forceH2 is true the transport
// attempts HTTP/2 negotiation.
func newProxyHTTPSClient(t *testing.T, proxyAddr string, roots *x509.CertPool, forceH2 bool) *http.Client {
	t.Helper()
	return &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp", proxyAddr)
			},
			TLSClientConfig: &tls.Config{
				RootCAs: roots,
			},
			ForceAttemptHTTP2: forceH2,
		},
	}
}
