package proxy

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"sync"
	"time"
)

// CAPool holds a CA certificate and key for issuing leaf certs.
type CAPool struct {
	caCert    *x509.Certificate
	caKey     *rsa.PrivateKey
	certCache sync.Map // hostname -> *tls.Certificate
}

// GenerateCA creates a new self-signed CA cert+key and returns a CAPool
// along with the PEM-encoded cert (for installing in the guest trust store).
func GenerateCA() (*CAPool, string, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, "", fmt.Errorf("generate CA key: %w", err)
	}

	serial, _ := rand.Int(rand.Reader, big.NewInt(1<<62))
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "DVM Sandbox CA"},
		NotBefore:    time.Now().Add(-5 * time.Minute),
		NotAfter:     time.Now().AddDate(1, 0, 0),
		KeyUsage:     x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
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

	return &CAPool{caCert: caCert, caKey: key}, string(certPEM), nil
}

// NewCAPool creates a CAPool from PEM-encoded cert and key.
// Returns nil (no error) if both are empty — HTTPS MITM will be disabled.
func NewCAPool(certPEM, keyPEM string) (*CAPool, error) {
	if certPEM == "" || keyPEM == "" {
		return nil, nil
	}

	certBlock, _ := pem.Decode([]byte(certPEM))
	if certBlock == nil {
		return nil, fmt.Errorf("failed to decode CA cert PEM")
	}
	caCert, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse CA cert: %w", err)
	}

	keyBlock, _ := pem.Decode([]byte(keyPEM))
	if keyBlock == nil {
		return nil, fmt.Errorf("failed to decode CA key PEM")
	}
	caKey, err := x509.ParsePKCS1PrivateKey(keyBlock.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse CA key: %w", err)
	}

	return &CAPool{
		caCert: caCert,
		caKey:  caKey,
	}, nil
}

// GetCertificate returns a leaf cert for the given hostname, generating and
// caching it on first use.
func (p *CAPool) GetCertificate(serverName string) (*tls.Certificate, error) {
	if cached, ok := p.certCache.Load(serverName); ok {
		return cached.(*tls.Certificate), nil
	}

	cert, err := p.generateLeafCert(serverName)
	if err != nil {
		return nil, err
	}

	p.certCache.Store(serverName, cert)
	return cert, nil
}

func (p *CAPool) generateLeafCert(serverName string) (*tls.Certificate, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}

	serialNumber, _ := rand.Int(rand.Reader, big.NewInt(1<<62))

	template := &x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName: serverName,
		},
		DNSNames:    []string{serverName},
		NotBefore:   time.Now().Add(-5 * time.Minute), // clock skew
		NotAfter:    time.Now().AddDate(1, 0, 0),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, p.caCert, &key.PublicKey, p.caKey)
	if err != nil {
		return nil, err
	}

	return &tls.Certificate{
		Certificate: [][]byte{certDER, p.caCert.Raw},
		PrivateKey:  key,
	}, nil
}
