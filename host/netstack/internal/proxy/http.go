// Package proxy implements HTTP/HTTPS interception and credential injection.
// It replaces placeholder tokens in request headers and URL query params with
// real secret values before forwarding upstream.
package proxy

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"strings"
	"sync"
	"time"

	"github.com/unbody/darvm/netstack/internal/control"
	"golang.org/x/net/http2"
)

type connInfoKey struct{}

type connInfo struct {
	scheme  string
	dstIP   string
	dstPort int
}

// Interceptor handles HTTP and HTTPS interception for credential injection.
type Interceptor struct {
	mu      sync.RWMutex
	secrets []control.SecretRule
	// hostIndex maps hostname -> []SecretRule for fast lookup.
	hostIndex map[string][]control.SecretRule
	caPool    *CAPool // nil if no CA configured (HTTPS MITM disabled)
	proxy     *httputil.ReverseProxy
}

// NewInterceptor creates an interceptor with the given secret rules and optional CA.
func NewInterceptor(secrets []control.SecretRule, caPool *CAPool) *Interceptor {
	i := &Interceptor{caPool: caPool}
	i.proxy = &httputil.ReverseProxy{
		Rewrite:       i.rewriteRequest,
		FlushInterval: -1, // immediate flush — no buffering surprises for SSE/streaming
	}
	i.UpdateSecrets(secrets)
	return i
}

// UpdateSecrets atomically replaces the secret rules.
func (i *Interceptor) UpdateSecrets(secrets []control.SecretRule) {
	index := make(map[string][]control.SecretRule)
	for _, s := range secrets {
		for _, h := range s.Hosts {
			index[normalizeHost(h)] = append(index[normalizeHost(h)], s)
		}
	}
	i.mu.Lock()
	i.secrets = secrets
	i.hostIndex = index
	i.mu.Unlock()
}

// secretsForHost returns the secret rules applicable to a host. Returns nil
// if the host is not in any secret's scope.
func (i *Interceptor) secretsForHost(host string) []control.SecretRule {
	// Strip port if present.
	h := host
	if idx := strings.LastIndex(h, ":"); idx != -1 {
		h = h[:idx]
	}
	i.mu.RLock()
	defer i.mu.RUnlock()
	return i.hostIndex[normalizeHost(h)]
}

// normalizeHost lowercases and strips trailing dots for consistent matching.
func normalizeHost(h string) string {
	h = strings.ToLower(h)
	return strings.TrimRight(h, ".")
}

// IsInterceptedHost returns true if the host has secret rules configured.
func (i *Interceptor) IsInterceptedHost(host string) bool {
	return len(i.secretsForHost(host)) > 0
}

// HandleHTTP handles an HTTP (port 80) connection from the guest.
// Both intercepted and non-intercepted hosts are routed through the
// ReverseProxy — secrets are applied when rules match, otherwise the
// request passes through unmodified. Keep-alive is handled by http.Server.
func (i *Interceptor) HandleHTTP(guestConn net.Conn, dstIP string, dstPort int) {
	defer guestConn.Close()
	i.serveConn(guestConn, "http", dstIP, dstPort, false)
}

// HandleHTTPS handles an HTTPS (port 443) connection from the guest.
// If the host is in the secrets config and a CA is configured, the connection
// is MITM'd: TLS terminated with a generated leaf cert, HTTP/2 negotiated
// via ALPN, and requests routed through the ReverseProxy for credential
// injection. Non-matching hosts get pure TCP passthrough.
func (i *Interceptor) HandleHTTPS(guestConn net.Conn, dstIP string, dstPort int) {
	defer guestConn.Close()

	if i.caPool == nil {
		// No CA — can't MITM. TCP passthrough.
		i.tcpPassthrough(guestConn, dstIP, dstPort)
		return
	}

	// Peek at the ClientHello to extract SNI before deciding whether to MITM.
	// Max TLS record body is 16384 bytes; +5 for the record header.
	br := bufio.NewReaderSize(guestConn, 16384+5)
	serverName := peekSNI(br)

	// Wrap so peeked bytes are replayed transparently to downstream consumers.
	bc := &bufferedConn{Reader: br, Conn: guestConn}

	if serverName == "" {
		// No SNI (IP-based request, non-TLS traffic, or malformed ClientHello).
		// Pass through instead of attempting MITM without a hostname.
		i.tcpPassthrough(bc, dstIP, dstPort)
		return
	}

	secrets := i.secretsForHost(serverName)
	if secrets == nil {
		// Not intercepted — TCP passthrough.
		i.tcpPassthrough(bc, dstIP, dstPort)
		return
	}

	// Intercepted host — MITM via TLS termination.
	tlsConn := tls.Server(bc, &tls.Config{
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			return i.caPool.GetCertificate(hello.ServerName)
		},
		NextProtos: []string{"h2", "http/1.1"},
	})
	if err := tlsConn.Handshake(); err != nil {
		log.Printf("https: TLS handshake failed: %v", err)
		return
	}

	// http.Server manages the connection lifecycle (keep-alive, HTTP/2, close).
	i.serveConn(tlsConn, "https", dstIP, dstPort, true)
}

// replaceSecrets performs placeholder -> real value substitution in request
// headers and URL query params, then applies inject rules for secrets that
// weren't already present via placeholders. Body is intentionally skipped.
func (i *Interceptor) replaceSecrets(req *http.Request, secrets []control.SecretRule) {
	for _, s := range secrets {
		if s.Value == "" {
			continue
		}

		// Phase 1: placeholder replacement (only if placeholder is configured).
		if s.Placeholder != "" {
			for key, vals := range req.Header {
				for j, v := range vals {
					if strings.Contains(v, s.Placeholder) {
						req.Header[key][j] = strings.ReplaceAll(v, s.Placeholder, s.Value)
					}
				}
			}

			if req.URL.RawQuery != "" && strings.Contains(req.URL.RawQuery, s.Placeholder) {
				req.URL.RawQuery = strings.ReplaceAll(req.URL.RawQuery, s.Placeholder, s.Value)
			}
		}

		// Phase 2: inject rules — synthesize headers if the real value isn't
		// already present (e.g. guest sent no placeholder at all).
		if s.Inject.Type == "" {
			continue
		}

		switch s.Inject.Type {
		case "bearer":
			expected := "Bearer " + s.Value
			if !headerContains(req, "Authorization", expected) {
				req.Header.Set("Authorization", expected)
			}
		case "basic":
			encoded := base64.StdEncoding.EncodeToString([]byte(s.Value))
			expected := "Basic " + encoded
			if !headerContains(req, "Authorization", expected) {
				req.Header.Set("Authorization", expected)
			}
		case "header":
			if s.Inject.Name != "" && !headerContains(req, s.Inject.Name, s.Value) {
				req.Header.Set(s.Inject.Name, s.Value)
			}
		}
	}
}

// headerContains returns true if any value of the named header contains substr.
func headerContains(req *http.Request, name, substr string) bool {
	for _, v := range req.Header.Values(name) {
		if strings.Contains(v, substr) {
			return true
		}
	}
	return false
}

// tcpPassthrough does a bidirectional byte relay without any inspection.
func (i *Interceptor) tcpPassthrough(guestConn net.Conn, dstIP string, dstPort int) {
	target := net.JoinHostPort(dstIP, fmt.Sprintf("%d", dstPort))
	realConn, err := net.DialTimeout("tcp", target, 30*time.Second)
	if err != nil {
		return
	}
	defer realConn.Close()

	done := make(chan struct{})
	go func() {
		io.Copy(realConn, guestConn)
		close(done)
	}()
	io.Copy(guestConn, realConn)
	<-done
}

// serveConn runs an http.Server over a single connection, using the shared
// ReverseProxy for request handling. The server handles keep-alive, HTTP/2
// (when enableH2 is true and the TLS connection negotiated h2), and
// connection lifecycle.
//
// The conn is passed directly to preserve its dynamic type (*tls.Conn) so
// http.Server can detect HTTP/2 via ALPN. Connection close is detected via
// ConnState(StateClosed). Note: hijacked connections (WebSocket upgrades)
// don't fire StateClosed, causing Serve to block. This is acceptable for
// our use case (API credential injection has no WebSocket traffic).
func (i *Interceptor) serveConn(conn net.Conn, scheme, dstIP string, dstPort int, enableH2 bool) {
	done := make(chan struct{})
	var doneOnce sync.Once

	ln := &singleConnListener{conn: conn, done: done}

	srv := &http.Server{
		Handler: i.proxy,
		ConnState: func(_ net.Conn, state http.ConnState) {
			if state == http.StateClosed {
				doneOnce.Do(func() { close(done) })
			}
		},
		ConnContext: func(ctx context.Context, _ net.Conn) context.Context {
			return context.WithValue(ctx, connInfoKey{}, &connInfo{
				scheme:  scheme,
				dstIP:   dstIP,
				dstPort: dstPort,
			})
		},
	}

	if enableH2 {
		http2.ConfigureServer(srv, nil)
	}

	srv.Serve(ln)
}

// rewriteRequest is the httputil.ReverseProxy Rewrite callback. It sets the
// target URL and applies credential injection for intercepted hosts.
func (i *Interceptor) rewriteRequest(pr *httputil.ProxyRequest) {
	info := pr.In.Context().Value(connInfoKey{}).(*connInfo)

	host := pr.In.Host
	if host == "" {
		host = info.dstIP
	}

	// Strip port from host for secret lookup.
	hostOnly := host
	if idx := strings.LastIndex(hostOnly, ":"); idx != -1 {
		hostOnly = hostOnly[:idx]
	}

	pr.Out.URL.Scheme = info.scheme
	pr.Out.URL.Host = net.JoinHostPort(hostOnly, fmt.Sprintf("%d", info.dstPort))

	secrets := i.secretsForHost(hostOnly)
	if secrets != nil {
		i.replaceSecrets(pr.Out, secrets)
	}
}

// singleConnListener wraps a single net.Conn as a net.Listener for use with
// http.Server.Serve. First Accept returns the connection; subsequent calls
// block until the ConnState callback signals the connection is closed, then
// return net.ErrClosed so Serve exits.
type singleConnListener struct {
	conn net.Conn
	once sync.Once
	done <-chan struct{}
}

func (l *singleConnListener) Accept() (net.Conn, error) {
	var c net.Conn
	l.once.Do(func() { c = l.conn })
	if c != nil {
		return c, nil
	}
	<-l.done
	return nil, net.ErrClosed
}

func (l *singleConnListener) Close() error   { return nil }
func (l *singleConnListener) Addr() net.Addr { return l.conn.LocalAddr() }

// peekSNI extracts the TLS SNI server name from a ClientHello by peeking at
// the buffered reader without consuming bytes. Returns empty string if the
// data isn't a TLS handshake, the ClientHello is malformed, or has no SNI.
func peekSNI(br *bufio.Reader) string {
	// Peek at TLS record header: 1 byte type + 2 bytes version + 2 bytes length.
	hdr, err := br.Peek(5)
	if err != nil || hdr[0] != 0x16 { // 0x16 = TLS Handshake
		return ""
	}
	recordLen := int(hdr[3])<<8 | int(hdr[4])
	if recordLen > 16384 {
		return ""
	}

	// Peek full TLS record (header + body) without consuming.
	record, err := br.Peek(5 + recordLen)
	if err != nil {
		return ""
	}

	// Feed the record to tls.Server to parse the ClientHello using Go's own
	// TLS implementation. GetConfigForClient captures the SNI and aborts.
	var sni string
	srv := tls.Server(sniConn{r: bytes.NewReader(record)}, &tls.Config{
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			sni = hello.ServerName
			return nil, fmt.Errorf("sni extracted")
		},
	})
	srv.Handshake() // expected to fail after capturing SNI
	return sni
}

// sniConn is a minimal net.Conn fed to tls.Server for ClientHello parsing.
// Only Read is functional; Write returns EOF to abort the handshake.
type sniConn struct {
	r io.Reader
	net.Conn // nil; satisfies interface without a real connection
}

func (c sniConn) Read(p []byte) (int, error)  { return c.r.Read(p) }
func (c sniConn) Write(p []byte) (int, error) { return 0, io.EOF }

// bufferedConn wraps a bufio.Reader with its underlying net.Conn so that
// peeked bytes are replayed transparently on Read.
type bufferedConn struct {
	*bufio.Reader
	net.Conn
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	return c.Reader.Read(p)
}
