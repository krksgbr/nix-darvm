// Package proxy implements HTTPS interception and credential injection.
// It replaces placeholder tokens in request headers with real secret values
// before forwarding upstream. Only HTTPS requests are rewritten; HTTP passes
// through without replacement to avoid leaking credentials over cleartext.
package proxy

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/unbody/darvm/netstack/internal/control"
	"golang.org/x/net/http2"
)

type connInfoKey struct{}

const (
	tlsRecordHeaderLength   = 5
	maxTLSRecordBodyLength  = 16384
	handshakeTimeout        = 30 * time.Second
	passthroughDialTimeout  = 30 * time.Second
	serverReadHeaderTimeout = 10 * time.Second
	tlsRecordLengthShift    = 8
)

var errSNIExtracted = errors.New("sni extracted")

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
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("proxy error forwarding request to %q: %v", r.Host, err) //nolint:gosec // G706: %q escapes control characters, preventing log injection
			w.WriteHeader(http.StatusBadGateway)
		},
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
	defer func() {
		if err := guestConn.Close(); err != nil {
			log.Printf("http: close guest conn: %v", err)
		}
	}()

	i.serveConn(guestConn, "http", dstIP, dstPort, false)
}

// HandleHTTPS handles an HTTPS (port 443) connection from the guest.
// If the host is in the secrets config and a CA is configured, the connection
// is MITM'd: TLS terminated with a generated leaf cert, HTTP/2 negotiated
// via ALPN, and requests routed through the ReverseProxy for credential
// injection. Non-matching hosts get pure TCP passthrough.
func (i *Interceptor) HandleHTTPS(guestConn net.Conn, dstIP string, dstPort int) {
	defer func() {
		if err := guestConn.Close(); err != nil {
			log.Printf("https: close guest conn: %v", err)
		}
	}()

	if i.caPool == nil {
		// No CA — can't MITM. TCP passthrough.
		i.tcpPassthrough(guestConn, dstIP, dstPort, "")

		return
	}

	// Peek at the ClientHello to extract SNI before deciding whether to MITM.
	// Max TLS record body is 16384 bytes; +5 for the record header.
	br := bufio.NewReaderSize(guestConn, maxTLSRecordBodyLength+tlsRecordHeaderLength)
	serverName := peekSNI(br)

	// Wrap so peeked bytes are replayed transparently to downstream consumers.
	bc := &bufferedConn{Reader: br, Conn: guestConn}

	if serverName == "" {
		// No SNI (IP-based request, non-TLS traffic, or malformed ClientHello).
		// Pass through instead of attempting MITM without a hostname.
		i.tcpPassthrough(bc, dstIP, dstPort, "")

		return
	}

	secrets := i.secretsForHost(serverName)
	if secrets == nil {
		// Not intercepted — TCP passthrough.
		i.tcpPassthrough(bc, dstIP, dstPort, serverName)

		return
	}

	// Intercepted host — MITM via TLS termination.
	tlsConn := tls.Server(bc, &tls.Config{
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			return i.caPool.GetCertificate(hello.ServerName)
		},
		NextProtos: []string{"h2", "http/1.1"},
	})

	handshakeCtx, cancelHandshake := context.WithTimeout(context.Background(), handshakeTimeout)
	defer cancelHandshake()

	if err := tlsConn.HandshakeContext(handshakeCtx); err != nil {
		log.Printf("https: TLS handshake failed for %s: %v", serverName, err)

		return
	}

	// http.Server manages the connection lifecycle (keep-alive, HTTP/2, close).
	i.serveConn(tlsConn, "https", dstIP, dstPort, true)
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

// replaceSecrets performs single-pass placeholder → real value substitution in
// request header values. Only runs for HTTPS (scheme must be in the request
// context). Body and query params are intentionally skipped — the guest tool
// places the placeholder in the appropriate header.
//
// "Single-pass" means each secret sees the original header values, not values
// already modified by a previous secret. This prevents chain replacement where
// secret A's resolved value accidentally contains secret B's placeholder.
func (i *Interceptor) replaceSecrets(req *http.Request, secrets []control.SecretRule, scheme string) {
	if scheme != "https" {
		return // never replace in plain HTTP — placeholder leaks as-is, upstream rejects it
	}

	// Snapshot original header values so each secret replaces against the
	// originals, not against already-substituted values.
	originals := make(map[string][]string, len(req.Header))
	for key, vals := range req.Header {
		cp := make([]string, len(vals))
		copy(cp, vals)
		originals[key] = cp
	}

	for _, s := range secrets {
		if s.Value == "" || s.Placeholder == "" {
			continue
		}

		for key, orig := range originals {
			for j, v := range orig {
				if strings.Contains(v, s.Placeholder) {
					req.Header[key][j] = strings.ReplaceAll(req.Header[key][j], s.Placeholder, s.Value)
				}
			}
		}
	}
}

// tcpPassthrough does a bidirectional byte relay without any inspection.
// serverName is the SNI hostname if known, empty string otherwise.
func (i *Interceptor) tcpPassthrough(guestConn net.Conn, dstIP string, dstPort int, serverName string) {
	target := net.JoinHostPort(dstIP, strconv.Itoa(dstPort))
	displayTarget := target
	if serverName != "" {
		displayTarget = serverName
	}
	dialer := &net.Dialer{Timeout: passthroughDialTimeout}

	realConn, err := dialer.DialContext(context.Background(), "tcp", target)
	if err != nil {
		return
	}

	defer func() {
		if err := realConn.Close(); err != nil && !isConnCloseError(err) {
			log.Printf("tcp passthrough: close upstream conn (%s): %v", displayTarget, err)
		}
	}()

	done := make(chan struct{})

	go func() {
		if _, err := io.Copy(realConn, guestConn); err != nil && !isConnCloseError(err) {
			log.Printf("tcp passthrough: guest to upstream copy (%s): %v", displayTarget, err)
		}

		close(done)
	}()

	if _, err := io.Copy(guestConn, realConn); err != nil && !isConnCloseError(err) {
		log.Printf("tcp passthrough: upstream to guest copy (%s): %v", displayTarget, err)
	}

	<-done
}

// isConnCloseError reports whether err is an expected error from a connection
// being torn down mid-copy: EOF, reset by peer, closed endpoint, broken pipe.
// These are normal in a bidirectional proxy when one side closes first.
//
// None of these can mask data corruption or security failures — they are all
// connection-state signals, not data-plane errors. The one observability cost:
// a premature teardown caused by a proxy or netstack bug would also match
// "endpoint is closed" and go unlogged. The client still sees the dropped
// connection; only the proxy-side log entry is suppressed.
func isConnCloseError(err error) bool {
	if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
		return true
	}
	msg := err.Error()
	return strings.Contains(msg, "connection reset by peer") ||
		strings.Contains(msg, "endpoint is closed") ||
		strings.Contains(msg, "use of closed network connection") ||
		strings.Contains(msg, "broken pipe")
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
		Handler:           i.proxy,
		ReadHeaderTimeout: serverReadHeaderTimeout,
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
		if err := http2.ConfigureServer(srv, nil); err != nil {
			log.Printf("proxy: configure http2: %v", err)

			return
		}
	}

	if err := srv.Serve(ln); err != nil && !errors.Is(err, net.ErrClosed) {
		log.Printf("proxy: serve conn: %v", err)
	}
}

// rewriteRequest is the httputil.ReverseProxy Rewrite callback. It sets the
// target URL and applies credential injection for intercepted hosts.
func (i *Interceptor) rewriteRequest(pr *httputil.ProxyRequest) {
	infoValue := pr.In.Context().Value(connInfoKey{})
	info, ok := infoValue.(*connInfo)
	if !ok || info == nil {
		log.Printf("proxy: missing conn info in request context")
		return
	}

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
	pr.Out.URL.Host = net.JoinHostPort(hostOnly, strconv.Itoa(info.dstPort))

	secrets := i.secretsForHost(hostOnly)
	if secrets != nil {
		i.replaceSecrets(pr.Out, secrets, info.scheme)
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
	hdr, err := br.Peek(tlsRecordHeaderLength)
	if err != nil || hdr[0] != 0x16 { // 0x16 = TLS Handshake
		return ""
	}

	recordLen := int(hdr[3])<<tlsRecordLengthShift | int(hdr[4])
	if recordLen > maxTLSRecordBodyLength {
		return ""
	}

	// Peek full TLS record (header + body) without consuming.
	record, err := br.Peek(tlsRecordHeaderLength + recordLen)
	if err != nil {
		return ""
	}

	// Feed the record to tls.Server to parse the ClientHello using Go's own
	// TLS implementation. GetConfigForClient captures the SNI and aborts.
	var sni string

	srv := tls.Server(sniConn{r: bytes.NewReader(record)}, &tls.Config{
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			sni = hello.ServerName

			return nil, errSNIExtracted
		},
	})
	if err := srv.HandshakeContext(context.Background()); err == nil {
		return sni
	}

	return sni
}

// sniConn is a minimal net.Conn fed to tls.Server for ClientHello parsing.
// Only Read is functional; Write returns EOF to abort the handshake.
type sniConn struct {
	r        io.Reader
	net.Conn // nil; satisfies interface without a real connection
}

func (c sniConn) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	if err != nil {
		return n, fmt.Errorf("read buffered client hello: %w", err)
	}

	return n, nil
}
func (c sniConn) Write(p []byte) (int, error) { return 0, io.EOF }

// bufferedConn wraps a bufio.Reader with its underlying net.Conn so that
// peeked bytes are replayed transparently on Read.
type bufferedConn struct {
	*bufio.Reader
	net.Conn
}

func (c *bufferedConn) Read(p []byte) (int, error) {
	n, err := c.Reader.Read(p)
	if err != nil {
		return n, fmt.Errorf("read buffered connection: %w", err)
	}

	return n, nil
}
