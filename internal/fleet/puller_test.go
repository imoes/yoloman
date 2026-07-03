package fleet

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

// generateSelfSignedCert creates a fresh ECDSA keypair and a self-signed
// certificate for it, returning the tls.Certificate (for serving) and the
// PEM-encoded PKIX public key (for pinning) — mirroring the real deployment
// where an operator runs `openssl x509 -pubkey -noout` against the
// satellite's cert to produce the file distributed to the proxy.
func generateSelfSignedCert(t *testing.T) (tls.Certificate, []byte) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "sat1.test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	derCert, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("creating certificate: %v", err)
	}
	cert := tls.Certificate{
		Certificate: [][]byte{derCert},
		PrivateKey:  priv,
	}

	pubDER, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatalf("marshaling public key: %v", err)
	}
	pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})
	return cert, pubPEM
}

func writePublicKeyFile(t *testing.T, pubPEM []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sat.pub.pem")
	if err := os.WriteFile(path, pubPEM, 0o600); err != nil {
		t.Fatalf("writing public key file: %v", err)
	}
	return path
}

func newMetricsServer(t *testing.T, cert tls.Certificate, wantToken string) *httptest.Server {
	t.Helper()
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/metrics" {
			http.NotFound(w, r)
			return
		}
		if wantToken != "" && r.Header.Get("Authorization") != "Bearer "+wantToken {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		resp := metricsDumpResponse{
			Metrics: map[string][]metricPoint{
				"cpu_pct": {
					{Timestamp: time.Now().UTC().Format(time.RFC3339), Value: 42, Labels: map[string]string{"core": "0"}},
				},
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	srv.StartTLS()
	return srv
}

func openTestStore(t *testing.T) store.Store {
	t.Helper()
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "fleet-test.db"))
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

func TestPuller_PullOnce_Success(t *testing.T) {
	cert, pubPEM := generateSelfSignedCert(t)
	srv := newMetricsServer(t, cert, "sat-token")
	defer srv.Close()

	pubKeyPath := writePublicKeyFile(t, pubPEM)
	st := openTestStore(t)

	p := &Puller{
		Satellite: config.Satellite{
			Name:          "sat1",
			Address:       srv.Listener.Addr().String(),
			PublicKeyPath: pubKeyPath,
			Token:         "sat-token",
		},
		Store: st,
	}

	from := time.Now().Add(-time.Hour)
	to := time.Now().Add(time.Hour)
	n, err := p.PullOnce(context.Background(), from, to)
	if err != nil {
		t.Fatalf("PullOnce: %v", err)
	}
	if n != 1 {
		t.Fatalf("expected 1 point pulled, got %d", n)
	}

	points, err := st.Query(context.Background(), "cpu_pct", from, to, map[string]string{"satellite": "sat1"}, store.ResolutionRaw)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if len(points) != 1 {
		t.Fatalf("expected 1 stored point labeled satellite=sat1, got %d", len(points))
	}
	if points[0].Value != 42 {
		t.Errorf("value = %v, want 42", points[0].Value)
	}
	if points[0].Labels["core"] != "0" {
		t.Errorf("expected original label 'core' to be preserved, got %+v", points[0].Labels)
	}
}

func TestPuller_PullOnce_RejectsWrongPinnedKey(t *testing.T) {
	cert, _ := generateSelfSignedCert(t)
	srv := newMetricsServer(t, cert, "")
	defer srv.Close()

	// Pin a different key than the one the server actually presents.
	_, otherPubPEM := generateSelfSignedCert(t)
	pubKeyPath := writePublicKeyFile(t, otherPubPEM)
	st := openTestStore(t)

	p := &Puller{
		Satellite: config.Satellite{
			Name:          "sat1",
			Address:       srv.Listener.Addr().String(),
			PublicKeyPath: pubKeyPath,
		},
		Store: st,
	}

	_, err := p.PullOnce(context.Background(), time.Now().Add(-time.Hour), time.Now())
	if err == nil {
		t.Fatal("expected error when the presented certificate's key does not match the pin")
	}
}

func TestPuller_PullOnce_RejectsMissingToken(t *testing.T) {
	cert, pubPEM := generateSelfSignedCert(t)
	srv := newMetricsServer(t, cert, "sat-token")
	defer srv.Close()

	pubKeyPath := writePublicKeyFile(t, pubPEM)
	st := openTestStore(t)

	p := &Puller{
		Satellite: config.Satellite{
			Name:          "sat1",
			Address:       srv.Listener.Addr().String(),
			PublicKeyPath: pubKeyPath,
			// Token deliberately omitted/wrong.
		},
		Store: st,
	}

	_, err := p.PullOnce(context.Background(), time.Now().Add(-time.Hour), time.Now())
	if err == nil {
		t.Fatal("expected error for missing/invalid bearer token")
	}
}

func TestPuller_PullOnce_MissingPublicKeyFile(t *testing.T) {
	st := openTestStore(t)
	p := &Puller{
		Satellite: config.Satellite{
			Name:          "sat1",
			Address:       "127.0.0.1:0",
			PublicKeyPath: "/nonexistent/path.pem",
		},
		Store: st,
	}
	_, err := p.PullOnce(context.Background(), time.Now().Add(-time.Hour), time.Now())
	if err == nil {
		t.Fatal("expected error for unreadable public_key_path")
	}
}
