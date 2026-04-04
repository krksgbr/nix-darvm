package proxy

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"sync"
	"time"
)

const (
	certificateSerialBits = 62
	leafCertificateTTL    = 24 * time.Hour
)

var (
	errMissingCAPEM      = errors.New("missing CA cert or key PEM")
	errDecodeCACertPEM   = errors.New("failed to decode CA cert PEM")
	errDecodeCAKeyPEM    = errors.New("failed to decode CA key PEM")
	errCAKeyNotSigner    = errors.New("CA key does not implement crypto.Signer")
	errUnsupportedKeyPEM = errors.New("unsupported CA key PEM type")
)

// CAPool holds a CA certificate and key for issuing leaf certs.
type CAPool struct {
	caCert    *x509.Certificate
	caKey     crypto.Signer
	cacheMu   sync.RWMutex
	certCache map[string]cachedCert
}

type cachedCert struct {
	cert     *tls.Certificate
	notAfter time.Time
}

// GenerateCA creates a new self-signed ECDSA-P256 CA cert+key and returns a
// CAPool along with the PEM-encoded cert (for installing in the guest trust store).
func GenerateCA() (*CAPool, string, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, "", fmt.Errorf("generate CA key: %w", err)
	}

	serial, _ := rand.Int(rand.Reader, big.NewInt(1<<certificateSerialBits))
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "DVM Sandbox CA"},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().AddDate(1, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, "", fmt.Errorf("create CA cert: %w", err)
	}

	caCert, err := x509.ParseCertificate(certDER)
	if err != nil {
		return nil, "", fmt.Errorf("parse CA cert: %w", err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})

	return &CAPool{
		caCert:    caCert,
		caKey:     key,
		certCache: make(map[string]cachedCert),
	}, string(certPEM), nil
}

// NewCAPool creates a CAPool from PEM-encoded cert and key.
// The key must be in PKCS#8 format (PEM type "PRIVATE KEY").
func NewCAPool(certPEM, keyPEM string) (*CAPool, error) {
	if certPEM == "" || keyPEM == "" {
		return nil, errMissingCAPEM
	}

	certBlock, _ := pem.Decode([]byte(certPEM))
	if certBlock == nil {
		return nil, errDecodeCACertPEM
	}

	caCert, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse CA cert: %w", err)
	}

	keyBlock, _ := pem.Decode([]byte(keyPEM))
	if keyBlock == nil {
		return nil, errDecodeCAKeyPEM
	}

	signer, err := parsePrivateKey(keyBlock)
	if err != nil {
		return nil, err
	}

	return &CAPool{
		caCert:    caCert,
		caKey:     signer,
		certCache: make(map[string]cachedCert),
	}, nil
}

// GetCertificate returns a leaf cert for the given hostname, generating and
// caching it on first use. Expired certs are regenerated automatically.
func (p *CAPool) GetCertificate(serverName string) (*tls.Certificate, error) {
	now := time.Now()

	p.cacheMu.RLock()

	if cached, ok := p.certCache[serverName]; ok && now.Before(cached.notAfter) {
		p.cacheMu.RUnlock()

		return cached.cert, nil
	}

	p.cacheMu.RUnlock()

	cert, notAfter, err := p.generateLeafCert(serverName)
	if err != nil {
		return nil, err
	}

	p.cacheMu.Lock()
	p.certCache[serverName] = cachedCert{cert: cert, notAfter: notAfter}
	p.cacheMu.Unlock()

	return cert, nil
}

func (p *CAPool) generateLeafCert(serverName string) (*tls.Certificate, time.Time, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, time.Time{}, fmt.Errorf("generate leaf key: %w", err)
	}

	serialNumber, _ := rand.Int(rand.Reader, big.NewInt(1<<certificateSerialBits))

	notAfter := time.Now().Add(leafCertificateTTL)
	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName: serverName,
		},
		DNSNames:    []string{serverName},
		NotBefore:   time.Now().Add(-1 * time.Hour),
		NotAfter:    notAfter,
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, p.caCert, &key.PublicKey, p.caKey)
	if err != nil {
		return nil, time.Time{}, fmt.Errorf("create leaf certificate for %q: %w", serverName, err)
	}

	return &tls.Certificate{
		Certificate: [][]byte{certDER, p.caCert.Raw},
		PrivateKey:  key,
	}, notAfter, nil
}

// parsePrivateKey parses a PEM block into a crypto.Signer, supporting the
// three standard private key encodings: PKCS#8, PKCS#1 (RSA), and SEC1 (EC).
func parsePrivateKey(block *pem.Block) (crypto.Signer, error) {
	switch block.Type {
	case "PRIVATE KEY": // PKCS#8 — any key type
		key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("parse CA key (PKCS#8): %w", err)
		}

		signer, ok := key.(crypto.Signer)
		if !ok {
			return nil, fmt.Errorf("%w: %T", errCAKeyNotSigner, key)
		}

		return signer, nil
	case "RSA PRIVATE KEY": // PKCS#1
		key, err := x509.ParsePKCS1PrivateKey(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("parse CA key (PKCS#1): %w", err)
		}

		return key, nil
	case "EC PRIVATE KEY": // SEC1
		key, err := x509.ParseECPrivateKey(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("parse CA key (SEC1): %w", err)
		}

		return key, nil
	default:
		return nil, fmt.Errorf("%w: %s", errUnsupportedKeyPEM, block.Type)
	}
}
