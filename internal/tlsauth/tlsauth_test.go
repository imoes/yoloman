package tlsauth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// generateCert creates a fresh ECDSA keypair and a self-signed certificate,
// returning the certificate and the PEM-encoded PKIX public key.
func generateCert(t *testing.T) (*x509.Certificate, []byte) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("creating certificate: %v", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parsing certificate: %v", err)
	}
	pubDER, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatalf("marshaling public key: %v", err)
	}
	pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})
	return cert, pubPEM
}

func writeKeyFile(t *testing.T, pubPEM []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "key.pub.pem")
	if err := os.WriteFile(path, pubPEM, 0o600); err != nil {
		t.Fatalf("writing key file: %v", err)
	}
	return path
}

func TestLoadTrustedKey_Success(t *testing.T) {
	_, pubPEM := generateCert(t)
	path := writeKeyFile(t, pubPEM)

	key, err := LoadTrustedKey("commander", path)
	if err != nil {
		t.Fatalf("LoadTrustedKey: %v", err)
	}
	if key.Name != "commander" {
		t.Errorf("Name = %q, want commander", key.Name)
	}
	if len(key.DER) == 0 {
		t.Error("expected non-empty DER")
	}
}

func TestLoadTrustedKey_MissingFile(t *testing.T) {
	_, err := LoadTrustedKey("commander", "/nonexistent/path.pem")
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestLoadTrustedKey_NotPEM(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notpem.txt")
	if err := os.WriteFile(path, []byte("not a pem file"), 0o600); err != nil {
		t.Fatalf("writing file: %v", err)
	}
	_, err := LoadTrustedKey("commander", path)
	if err == nil {
		t.Fatal("expected error for non-PEM content")
	}
}

func TestMatchesAny_MatchingKey(t *testing.T) {
	cert, pubPEM := generateCert(t)
	path := writeKeyFile(t, pubPEM)
	key, err := LoadTrustedKey("commander", path)
	if err != nil {
		t.Fatalf("LoadTrustedKey: %v", err)
	}

	matched, ok := MatchesAny(cert, []TrustedKey{key})
	if !ok {
		t.Fatal("expected cert to match its own pinned key")
	}
	if matched.Name != "commander" {
		t.Errorf("matched.Name = %q, want commander", matched.Name)
	}
}

func TestMatchesAny_NoMatch(t *testing.T) {
	cert, _ := generateCert(t)
	_, otherPubPEM := generateCert(t)
	path := writeKeyFile(t, otherPubPEM)
	key, err := LoadTrustedKey("someone-else", path)
	if err != nil {
		t.Fatalf("LoadTrustedKey: %v", err)
	}

	_, ok := MatchesAny(cert, []TrustedKey{key})
	if ok {
		t.Fatal("expected no match against an unrelated pinned key")
	}
}

func TestMatchesAny_EmptyList(t *testing.T) {
	cert, _ := generateCert(t)
	_, ok := MatchesAny(cert, nil)
	if ok {
		t.Fatal("expected no match against an empty trusted key list")
	}
}
