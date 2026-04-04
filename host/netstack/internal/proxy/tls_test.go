package proxy

import (
	"bufio"
	"bytes"
	"testing"
)

// TestPeekSNI_ValidClientHello writes a real TLS ClientHello into a
// bufio.Reader and verifies that peekSNI extracts the correct server name.
func TestPeekSNI_ValidClientHello(t *testing.T) {
	serverName := "api.example.com"

	hello := tlsClientHelloBytes(t, serverName)
	if len(hello) == 0 {
		t.Fatal("generated empty ClientHello")
	}

	br := bufio.NewReaderSize(bytes.NewReader(hello), 16384+5)

	got := peekSNI(br)
	if got != serverName {
		t.Fatalf("peekSNI = %q, want %q", got, serverName)
	}
}

// TestPeekSNI_GarbageInput verifies that garbage bytes produce an empty result
// without panicking.
func TestPeekSNI_GarbageInput(t *testing.T) {
	garbage := []byte("this is not a TLS ClientHello at all")
	br := bufio.NewReaderSize(bytes.NewReader(garbage), 16384+5)

	got := peekSNI(br)
	if got != "" {
		t.Fatalf("peekSNI on garbage = %q, want empty", got)
	}
}

// TestCAPool_CachesAndExpires verifies that GetCertificate returns the same
// cert on repeated calls (cache hit) and regenerates expired certs.
func TestCAPool_CachesAndExpires(t *testing.T) {
	caPool, _ := newTestCA(t)

	// First call generates and caches.
	cert1, err := caPool.GetCertificate("cached.example.com")
	if err != nil {
		t.Fatalf("GetCertificate: %v", err)
	}

	// Second call should return the same cached cert.
	cert2, err := caPool.GetCertificate("cached.example.com")
	if err != nil {
		t.Fatalf("GetCertificate: %v", err)
	}

	if cert1 != cert2 {
		t.Fatal("expected same cert pointer on cache hit")
	}

	// Force expiry by manipulating the cache entry.
	caPool.cacheMu.Lock()
	entry := caPool.certCache["cached.example.com"]
	entry.notAfter = entry.notAfter.AddDate(-1, 0, 0) // set to the past
	caPool.certCache["cached.example.com"] = entry
	caPool.cacheMu.Unlock()

	// Third call should regenerate because the cert is expired.
	cert3, err := caPool.GetCertificate("cached.example.com")
	if err != nil {
		t.Fatalf("GetCertificate after expiry: %v", err)
	}

	if cert3 == cert1 {
		t.Fatal("expected different cert after expiry, got same pointer")
	}
}

// TestPeekSNI_ShortInput verifies that input too short for a TLS record header
// returns empty string without panicking.
func TestPeekSNI_ShortInput(t *testing.T) {
	short := []byte{0x16, 0x03} // only 2 bytes, need at least 5
	br := bufio.NewReaderSize(bytes.NewReader(short), 16384+5)

	got := peekSNI(br)
	if got != "" {
		t.Fatalf("peekSNI on short input = %q, want empty", got)
	}
}

// TestPeekSNI_EmptyReader verifies peekSNI handles an empty reader gracefully.
func TestPeekSNI_EmptyReader(t *testing.T) {
	br := bufio.NewReaderSize(bytes.NewReader(nil), 16384+5)

	got := peekSNI(br)
	if got != "" {
		t.Fatalf("peekSNI on empty = %q, want empty", got)
	}
}

// TestPeekSNI_DoesNotConsume verifies that peekSNI does not consume bytes from
// the reader — the full ClientHello is still available for subsequent reads.
func TestPeekSNI_DoesNotConsume(t *testing.T) {
	hello := tlsClientHelloBytes(t, "nodelete.example.com")
	if len(hello) == 0 {
		t.Fatal("generated empty ClientHello")
	}

	br := bufio.NewReaderSize(bytes.NewReader(hello), 16384+5)
	_ = peekSNI(br)

	// All original bytes should still be readable.
	remaining := make([]byte, len(hello))

	n, _ := br.Read(remaining)
	if n != len(hello) {
		t.Fatalf("after peekSNI, read %d bytes, expected %d", n, len(hello))
	}

	if !bytes.Equal(remaining[:n], hello) {
		t.Fatal("peekSNI consumed or corrupted bytes in the reader")
	}
}
