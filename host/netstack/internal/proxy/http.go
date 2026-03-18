// Package proxy implements HTTP/HTTPS interception and credential injection.
// It replaces placeholder tokens in request headers and URL query params with
// real secret values before forwarding upstream.
package proxy

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/unbody/darvm/netstack/internal/control"
)

// Interceptor handles HTTP and HTTPS interception for credential injection.
type Interceptor struct {
	mu      sync.RWMutex
	secrets []control.SecretRule
	// hostIndex maps hostname -> []SecretRule for fast lookup.
	hostIndex map[string][]control.SecretRule
	caPool    *CAPool // nil if no CA configured (HTTPS MITM disabled)
}

// NewInterceptor creates an interceptor with the given secret rules and optional CA.
func NewInterceptor(secrets []control.SecretRule, caPool *CAPool) *Interceptor {
	i := &Interceptor{caPool: caPool}
	i.UpdateSecrets(secrets)
	return i
}

// UpdateSecrets atomically replaces the secret rules.
func (i *Interceptor) UpdateSecrets(secrets []control.SecretRule) {
	index := make(map[string][]control.SecretRule)
	for _, s := range secrets {
		for _, h := range s.Hosts {
			index[h] = append(index[h], s)
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
	return i.hostIndex[h]
}

// IsInterceptedHost returns true if the host has secret rules configured.
func (i *Interceptor) IsInterceptedHost(host string) bool {
	return len(i.secretsForHost(host)) > 0
}

// HandleHTTP handles an HTTP (port 80) connection from the guest.
// If the destination host is in the secrets config, requests are intercepted
// and placeholders replaced. Otherwise, passthrough.
func (i *Interceptor) HandleHTTP(guestConn net.Conn, dstIP string, dstPort int) {
	defer guestConn.Close()

	reader := bufio.NewReader(guestConn)

	for {
		req, err := http.ReadRequest(reader)
		if err != nil {
			return
		}

		host := req.Host
		if host == "" {
			host = dstIP
		}

		// Strip port from host for matching.
		hostOnly := host
		if idx := strings.LastIndex(hostOnly, ":"); idx != -1 {
			hostOnly = hostOnly[:idx]
		}

		secrets := i.secretsForHost(hostOnly)
		if secrets == nil {
			// Not in scope — passthrough this connection.
			// For simplicity, we forward this single request and continue the loop.
			i.forwardUnmodified(guestConn, req, host, dstPort)
			return
		}

		// Inject credentials.
		i.replaceSecrets(req, secrets)

		target := net.JoinHostPort(hostOnly, fmt.Sprintf("%d", dstPort))
		upstream, err := net.DialTimeout("tcp", target, 30*time.Second)
		if err != nil {
			writeHTTPError(guestConn, http.StatusBadGateway, "Failed to connect to upstream")
			return
		}

		if err := req.Write(upstream); err != nil {
			upstream.Close()
			writeHTTPError(guestConn, http.StatusBadGateway, "Failed to write request")
			return
		}

		resp, err := http.ReadResponse(bufio.NewReader(upstream), req)
		if err != nil {
			upstream.Close()
			return
		}

		if isStreamingResponse(resp) {
			writeResponseHeadersAndStreamBody(guestConn, resp)
			resp.Body.Close()
			upstream.Close()
			return
		}

		err = writeResponse(guestConn, resp)
		resp.Body.Close()
		upstream.Close()
		if err != nil {
			return
		}

		if req.Close || resp.Close {
			return
		}
	}
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

// forwardUnmodified does a simple passthrough relay for a non-intercepted HTTP request.
func (i *Interceptor) forwardUnmodified(guestConn net.Conn, req *http.Request, host string, dstPort int) {
	hostOnly := host
	if idx := strings.LastIndex(hostOnly, ":"); idx != -1 {
		hostOnly = hostOnly[:idx]
	}
	target := net.JoinHostPort(hostOnly, fmt.Sprintf("%d", dstPort))
	upstream, err := net.DialTimeout("tcp", target, 30*time.Second)
	if err != nil {
		writeHTTPError(guestConn, http.StatusBadGateway, "Failed to connect")
		return
	}
	defer upstream.Close()

	if err := req.Write(upstream); err != nil {
		return
	}

	resp, err := http.ReadResponse(bufio.NewReader(upstream), req)
	if err != nil {
		return
	}

	if isStreamingResponse(resp) {
		writeResponseHeadersAndStreamBody(guestConn, resp)
		resp.Body.Close()
		return
	}

	writeResponse(guestConn, resp)
	resp.Body.Close()
}

// HandleHTTPS handles an HTTPS (port 443) connection from the guest.
// If the host is in the secrets config and a CA is configured, the connection
// is MITM'd: TLS terminated with a generated leaf cert, HTTP parsed and
// credentials injected, then forwarded over a new TLS connection to the
// real upstream. Non-matching hosts get pure TCP passthrough.
func (i *Interceptor) HandleHTTPS(guestConn net.Conn, dstIP string, dstPort int) {
	defer guestConn.Close()

	if i.caPool == nil {
		// No CA — can't MITM. TCP passthrough.
		i.tcpPassthrough(guestConn, dstIP, dstPort)
		return
	}

	// Peek at the ClientHello to extract SNI before deciding whether to MITM.
	// This avoids TLS-terminating connections to non-intercepted hosts.
	peeked, serverName, err := peekClientHelloSNI(guestConn)
	if err != nil {
		log.Printf("https: failed to peek ClientHello: %v", err)
		return
	}
	if serverName == "" {
		serverName = dstIP
	}

	secrets := i.secretsForHost(serverName)
	if secrets == nil {
		// Not intercepted — TCP passthrough with peeked bytes replayed.
		i.tcpPassthroughWithPeeked(peeked, guestConn, dstIP, dstPort)
		return
	}

	// Intercepted host — MITM via TLS termination.
	// Wrap guestConn so the already-peeked bytes are replayed to tls.Server.
	bufferedConn := &prefixConn{reader: io.MultiReader(bytes.NewReader(peeked), guestConn), Conn: guestConn}

	tlsConn := tls.Server(bufferedConn, &tls.Config{
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			return i.caPool.GetCertificate(hello.ServerName)
		},
	})

	if err := tlsConn.Handshake(); err != nil {
		log.Printf("https: TLS handshake failed: %v", err)
		return
	}
	defer tlsConn.Close()

	// Connect to the real upstream over TLS.
	realConn, err := tls.Dial("tcp",
		net.JoinHostPort(serverName, fmt.Sprintf("%d", dstPort)),
		&tls.Config{ServerName: serverName})
	if err != nil {
		log.Printf("https: upstream dial %s: %v", serverName, err)
		return
	}
	defer realConn.Close()

	guestReader := bufio.NewReader(tlsConn)
	serverReader := bufio.NewReader(realConn)

	for {
		req, err := http.ReadRequest(guestReader)
		if err != nil {
			return
		}

		// Inject credentials.
		i.replaceSecrets(req, secrets)

		if err := req.Write(realConn); err != nil {
			return
		}

		resp, err := http.ReadResponse(serverReader, req)
		if err != nil {
			return
		}

		if isStreamingResponse(resp) {
			writeResponseHeadersAndStreamBody(tlsConn, resp)
			resp.Body.Close()
			return
		}

		err = writeResponse(tlsConn, resp)
		resp.Body.Close()
		if err != nil {
			return
		}

		if req.Close || resp.Close {
			return
		}
	}
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

// tcpPassthroughWithPeeked does a bidirectional byte relay, replaying already-peeked
// bytes to the upstream before relaying the rest of the guest connection.
func (i *Interceptor) tcpPassthroughWithPeeked(peeked []byte, guestConn net.Conn, dstIP string, dstPort int) {
	target := net.JoinHostPort(dstIP, fmt.Sprintf("%d", dstPort))
	realConn, err := net.DialTimeout("tcp", target, 30*time.Second)
	if err != nil {
		return
	}
	defer realConn.Close()

	// Replay the peeked bytes first.
	if _, err := realConn.Write(peeked); err != nil {
		return
	}

	done := make(chan struct{})
	go func() {
		io.Copy(realConn, guestConn)
		close(done)
	}()
	io.Copy(guestConn, realConn)
	<-done
}

// prefixConn wraps a net.Conn, prepending already-read bytes via a custom reader.
type prefixConn struct {
	reader io.Reader
	net.Conn
}

func (c *prefixConn) Read(p []byte) (int, error) {
	return c.reader.Read(p)
}

// peekClientHelloSNI reads just enough from conn to parse the TLS ClientHello
// and extract the SNI server name. Returns the bytes read (to be replayed) and
// the server name. Returns an error if the data isn't a valid ClientHello.
func peekClientHelloSNI(conn net.Conn) ([]byte, string, error) {
	// TLS record header: 1 byte content type + 2 bytes version + 2 bytes length.
	header := make([]byte, 5)
	if _, err := io.ReadFull(conn, header); err != nil {
		return nil, "", fmt.Errorf("read TLS record header: %w", err)
	}

	// Content type 22 = Handshake.
	if header[0] != 22 {
		return header, "", fmt.Errorf("not a TLS handshake record (type=%d)", header[0])
	}

	recordLen := int(header[3])<<8 | int(header[4])
	if recordLen > 16384 {
		return header, "", fmt.Errorf("TLS record too large: %d", recordLen)
	}

	record := make([]byte, recordLen)
	if _, err := io.ReadFull(conn, record); err != nil {
		// Return what we have so passthrough can still work.
		partial := append(header, record...)
		return partial, "", fmt.Errorf("read TLS record body: %w", err)
	}

	peeked := append(header, record...)
	sni := extractSNI(record)
	return peeked, sni, nil
}

// extractSNI parses a TLS Handshake message (the record body, not including
// the 5-byte record header) and returns the SNI server name if present.
func extractSNI(handshake []byte) string {
	// Handshake: 1 byte type + 3 bytes length.
	if len(handshake) < 4 {
		return ""
	}
	// Type 1 = ClientHello.
	if handshake[0] != 1 {
		return ""
	}

	// Skip handshake header (4 bytes), client version (2), random (32).
	pos := 4 + 2 + 32
	if pos >= len(handshake) {
		return ""
	}

	// Session ID (1 byte length + variable).
	sessionIDLen := int(handshake[pos])
	pos += 1 + sessionIDLen
	if pos+2 > len(handshake) {
		return ""
	}

	// Cipher suites (2 byte length + variable).
	cipherLen := int(handshake[pos])<<8 | int(handshake[pos+1])
	pos += 2 + cipherLen
	if pos+1 > len(handshake) {
		return ""
	}

	// Compression methods (1 byte length + variable).
	compLen := int(handshake[pos])
	pos += 1 + compLen
	if pos+2 > len(handshake) {
		return ""
	}

	// Extensions (2 byte length + variable).
	extLen := int(handshake[pos])<<8 | int(handshake[pos+1])
	pos += 2
	extEnd := pos + extLen
	if extEnd > len(handshake) {
		extEnd = len(handshake)
	}

	for pos+4 <= extEnd {
		extType := int(handshake[pos])<<8 | int(handshake[pos+1])
		extDataLen := int(handshake[pos+2])<<8 | int(handshake[pos+3])
		pos += 4

		if pos+extDataLen > extEnd {
			break
		}

		// Extension type 0 = server_name.
		if extType == 0 {
			return parseSNIExtension(handshake[pos : pos+extDataLen])
		}
		pos += extDataLen
	}

	return ""
}

// parseSNIExtension parses the SNI extension data and returns the first
// host_name entry.
func parseSNIExtension(data []byte) string {
	if len(data) < 2 {
		return ""
	}
	// Server name list length.
	listLen := int(data[0])<<8 | int(data[1])
	pos := 2
	end := pos + listLen
	if end > len(data) {
		end = len(data)
	}

	for pos+3 <= end {
		nameType := data[pos]
		nameLen := int(data[pos+1])<<8 | int(data[pos+2])
		pos += 3
		if pos+nameLen > end {
			break
		}
		// Name type 0 = host_name.
		if nameType == 0 {
			return string(data[pos : pos+nameLen])
		}
		pos += nameLen
	}
	return ""
}

func writeHTTPError(conn net.Conn, status int, message string) {
	resp := fmt.Sprintf("HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status, http.StatusText(status), len(message), message)
	io.WriteString(conn, resp)
}

func writeResponse(conn net.Conn, resp *http.Response) error {
	bw := bufio.NewWriterSize(conn, 64*1024)
	if err := resp.Write(bw); err != nil {
		return err
	}
	return bw.Flush()
}

func isStreamingResponse(resp *http.Response) bool {
	ct := resp.Header.Get("Content-Type")
	if strings.HasPrefix(ct, "text/event-stream") {
		return true
	}
	for _, te := range resp.TransferEncoding {
		if te == "chunked" {
			return true
		}
	}
	if resp.ContentLength == -1 && resp.ProtoMajor == 1 && resp.ProtoMinor == 1 {
		return true
	}
	return false
}

func writeResponseHeadersAndStreamBody(conn net.Conn, resp *http.Response) error {
	bw := bufio.NewWriterSize(conn, 4*1024)

	statusLine := fmt.Sprintf("HTTP/%d.%d %d %s\r\n",
		resp.ProtoMajor, resp.ProtoMinor, resp.StatusCode, http.StatusText(resp.StatusCode))
	if _, err := bw.WriteString(statusLine); err != nil {
		return err
	}
	if err := resp.Header.Write(bw); err != nil {
		return err
	}
	if _, err := bw.WriteString("\r\n"); err != nil {
		return err
	}
	if err := bw.Flush(); err != nil {
		return err
	}

	buf := make([]byte, 4*1024)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, writeErr := conn.Write(buf[:n]); writeErr != nil {
				return writeErr
			}
		}
		if readErr != nil {
			if readErr == io.EOF {
				return nil
			}
			return readErr
		}
	}
}

