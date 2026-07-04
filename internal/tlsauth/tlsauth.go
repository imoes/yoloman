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
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
)

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
