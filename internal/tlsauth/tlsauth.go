// Package tlsauth implements client-certificate authorization for this
// agent's REST/MCP API: the SSH authorized_keys model, but over TLS. Each
// agent can pin a list of trusted client public keys (see
// config.TLS.TrustedClientKeys); a machine caller (a Fleet Commander, or
// another agent acting as a proxy) authenticates itself by presenting a
// TLS client certificate whose public key matches one of those pins,
// checked in addition to the existing bearer token — see docs/plan.md's
// "Three operating modes".
package tlsauth

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

// EnsureSelfSigned generates a self-signed ECDSA (P-256) certificate + key at
// certPath/keyPath if either is missing, and returns nil if they already
// exist. The agent's TLS server cert only needs to be self-signed: Bossman
// pulls with verify=False (it authorizes the agent by bearer token + its own
// client cert, not by a CA chain). Lets `register` bootstrap TLS with zero
// manual openssl steps.
func EnsureSelfSigned(certPath, keyPath, commonName string) error {
	if fileExists(certPath) && fileExists(keyPath) {
		return nil
	}
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generating key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return fmt.Errorf("generating serial: %w", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: commonName},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return fmt.Errorf("creating certificate: %w", err)
	}
	keyDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return fmt.Errorf("marshaling key: %w", err)
	}
	for _, d := range []string{filepath.Dir(certPath), filepath.Dir(keyPath)} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("creating %q: %w", d, err)
		}
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return fmt.Errorf("writing %q: %w", certPath, err)
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return fmt.Errorf("writing %q: %w", keyPath, err)
	}
	return nil
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

// TrustedKey is one authorized caller's pinned public key: a name (for
// logging/audit) and its canonical DER-encoded PKIX SubjectPublicKeyInfo.
type TrustedKey struct {
	Name string
	DER  []byte
}

// LoadTrustedKey reads and parses a PEM-encoded PKIX public key file (e.g.
// produced by `openssl x509 -pubkey -noout` against the caller's own
// client certificate), returning its canonical DER encoding for comparison.
func LoadTrustedKey(name, path string) (TrustedKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return TrustedKey{}, fmt.Errorf("reading public key %q: %w", path, err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return TrustedKey{}, fmt.Errorf("public key %q: not a PEM file", path)
	}
	key, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return TrustedKey{}, fmt.Errorf("public key %q: parsing PKIX public key: %w", path, err)
	}
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		return TrustedKey{}, fmt.Errorf("public key %q: re-marshaling public key: %w", path, err)
	}
	return TrustedKey{Name: name, DER: der}, nil
}

// MatchesAny reports whether cert's public key matches any of keys, by
// comparing DER-encoded SubjectPublicKeyInfo bytes, and returns the
// matching entry.
func MatchesAny(cert *x509.Certificate, keys []TrustedKey) (TrustedKey, bool) {
	presented, err := x509.MarshalPKIXPublicKey(cert.PublicKey)
	if err != nil {
		return TrustedKey{}, false
	}
	for _, k := range keys {
		if bytes.Equal(presented, k.DER) {
			return k, true
		}
	}
	return TrustedKey{}, false
}

// PublicKeyPEMFromCertFile reads a PEM-encoded X.509 certificate file (e.g.
// a proxy's own client_cert_file, the identity it presents when it later
// polls a satellite) and returns its public key, PEM-encoded as PKIX
// SubjectPublicKeyInfo — the exact shape LoadTrustedKey expects to read
// back on the other end. Used by the enrollment endpoint (see
// docs/plan.md's Selecta design) to hand out "the public key of the
// identity that will actually connect to you" without needing a second,
// separate keypair just for enrollment.
func PublicKeyPEMFromCertFile(certFile string) ([]byte, error) {
	data, err := os.ReadFile(certFile)
	if err != nil {
		return nil, fmt.Errorf("reading certificate %q: %w", certFile, err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("certificate %q: not a PEM file", certFile)
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("certificate %q: parsing: %w", certFile, err)
	}
	der, err := x509.MarshalPKIXPublicKey(cert.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("certificate %q: marshaling public key: %w", certFile, err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}), nil
}
