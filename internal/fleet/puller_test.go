package fleet

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

// generateCertPair creates a fresh ECDSA keypair and self-signed
// certificate, written out as a PEM cert+key pair on disk (as
// tls.LoadX509KeyPair / tls.X509KeyPair expect), and returns the parsed
// tls.Certificate plus the DER-encoded public key for comparisons.
func generateCertPair(t *testing.T, cn string) (tls.Certificate, []byte) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: cn},
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
	return cert, pubDER
}

// newSatelliteServer starts a real TLS test server that mimics a satellite
// requiring a trusted client certificate (see cmd/agentic-mcpd/http.go's
// requireTrustedClientCert): it requests a client cert during the TLS
// handshake and rejects the connection unless the presented certificate's
// public key matches trustedClientKeyDER.
func newSatelliteServer(t *testing.T, serverCert tls.Certificate, trustedClientKeyDER []byte, wantToken string) *httptest.Server {
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
	srv.TLS = &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientAuth:   tls.RequireAnyClientCert,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return fmt.Errorf("no client certificate presented")
			}
			cert, err := x509.ParseCertificate(rawCerts[0])
			if err != nil {
				return err
			}
			presentedDER, err := x509.MarshalPKIXPublicKey(cert.PublicKey)
			if err != nil {
				return err
			}
			if !bytes.Equal(presentedDER, trustedClientKeyDER) {
				return fmt.Errorf("client certificate not trusted")
			}
			return nil
		},
	}
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
	serverCert, _ := generateCertPair(t, "sat1.test")
	clientCert, clientPubDER := generateCertPair(t, "proxy-e2e")
	srv := newSatelliteServer(t, serverCert, clientPubDER, "sat-token")
	defer srv.Close()

	st := openTestStore(t)
	p := &Puller{
		Satellite: config.Satellite{
			Name:    "sat1",
			Address: srv.Listener.Addr().String(),
			Token:   "sat-token",
		},
		ClientCert: clientCert,
		Store:      st,
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

func TestPuller_PullOnce_RejectsUntrustedClientCert(t *testing.T) {
	serverCert, _ := generateCertPair(t, "sat1.test")
	_, trustedClientPubDER := generateCertPair(t, "the-real-proxy")
	// This puller presents a DIFFERENT client cert than the one the
	// satellite trusts.
	wrongClientCert, _ := generateCertPair(t, "an-impostor")
	srv := newSatelliteServer(t, serverCert, trustedClientPubDER, "")
	defer srv.Close()

	st := openTestStore(t)
	p := &Puller{
		Satellite:  config.Satellite{Name: "sat1", Address: srv.Listener.Addr().String()},
		ClientCert: wrongClientCert,
		Store:      st,
	}

	_, err := p.PullOnce(context.Background(), time.Now().Add(-time.Hour), time.Now())
	if err == nil {
		t.Fatal("expected error when this proxy's client certificate is not trusted by the satellite")
	}
}

func TestPuller_PullOnce_RejectsMissingToken(t *testing.T) {
	serverCert, _ := generateCertPair(t, "sat1.test")
	clientCert, clientPubDER := generateCertPair(t, "proxy-e2e")
	srv := newSatelliteServer(t, serverCert, clientPubDER, "sat-token")
	defer srv.Close()

	st := openTestStore(t)
	p := &Puller{
		Satellite:  config.Satellite{Name: "sat1", Address: srv.Listener.Addr().String()},
		ClientCert: clientCert,
		// Token deliberately omitted.
		Store: st,
	}

	_, err := p.PullOnce(context.Background(), time.Now().Add(-time.Hour), time.Now())
	if err == nil {
		t.Fatal("expected error for missing/invalid bearer token")
	}
}

func TestLoadClientCert_MissingFiles(t *testing.T) {
	_, err := LoadClientCert("/nonexistent/cert.pem", "/nonexistent/key.pem")
	if err == nil {
		t.Fatal("expected error for missing cert/key files")
	}
}
