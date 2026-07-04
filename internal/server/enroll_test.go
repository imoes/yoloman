package server

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/fleet"
)

func satelliteFor(t *testing.T, name string) config.Satellite {
	t.Helper()
	return config.Satellite{Name: name, Address: name + ".example.com:8010", Token: "tok"}
}

// generateTestClientCert creates a throwaway self-signed certificate for
// wiring a real fleet.Manager in these tests — its poller goroutines will
// simply fail to reach the fake satellite addresses used below, which is
// harmless for testing the REST layer (the actual polling mechanics are
// already covered by internal/fleet's own tests).
func generateTestClientCert(t *testing.T) tls.Certificate {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test-selecta"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("creating certificate: %v", err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
}

func newTestEnrollServer(t *testing.T, write bool, enrollSecret string) (*httptest.Server, *fleet.Manager) {
	t.Helper()
	registry, err := fleet.OpenRegistry(filepath.Join(t.TempDir(), "satellites.db"))
	if err != nil {
		t.Fatalf("OpenRegistry: %v", err)
	}
	t.Cleanup(func() { registry.Close() })

	cert := generateTestClientCert(t)
	manager := fleet.NewManager(registry, cert, nil)
	t.Cleanup(manager.Close)

	handler := NewRESTHandler(RESTConfig{
		Write:             write,
		Mode:              "proxy",
		ProxyEnrollSecret: enrollSecret,
		ProxyPublicKeyPEM: []byte("-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----\n"),
		SatelliteManager:  manager,
	})
	return httptest.NewServer(handler), manager
}

func TestHandleEnroll_Success(t *testing.T) {
	srv, manager := newTestEnrollServer(t, true, "shared-secret")
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/enroll", map[string]any{
		"name": "duppy1", "enroll_secret": "shared-secret", "token": "duppy1-token", "address": "duppy1.example.com:8010",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	body := decodeJSON(t, resp)
	if body["bossman_public_key"] == "" || body["bossman_public_key"] == nil {
		t.Errorf("expected a non-empty public key in the response, got %+v", body)
	}
	if body["agent_id"] != "duppy1" {
		t.Errorf("agent_id = %v, want duppy1", body["agent_id"])
	}

	sats, err := manager.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(sats) != 1 || sats[0].Name != "duppy1" || sats[0].Address != "duppy1.example.com:8010" {
		t.Errorf("expected the enrolled satellite in the manager's list, got %+v", sats)
	}
}

func TestHandleEnroll_WrongSecretRejected(t *testing.T) {
	srv, _ := newTestEnrollServer(t, true, "shared-secret")
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/enroll", map[string]any{
		"name": "duppy1", "enroll_secret": "wrong", "token": "tok", "address": "duppy1.example.com:8010",
	})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401 for a wrong enroll_secret", resp.StatusCode)
	}
}

func TestHandleEnroll_MissingAddressRejected(t *testing.T) {
	srv, _ := newTestEnrollServer(t, true, "shared-secret")
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/enroll", map[string]any{
		"name": "duppy1", "enroll_secret": "shared-secret", "token": "tok",
	})
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("status = %d, want 400 when address is missing", resp.StatusCode)
	}
}

func TestHandleEnroll_NotRegisteredWhenWriteFalse(t *testing.T) {
	srv, _ := newTestEnrollServer(t, false, "shared-secret")
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/enroll", map[string]any{
		"name": "duppy1", "enroll_secret": "shared-secret", "token": "tok", "address": "duppy1.example.com:8010",
	})
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("status = %d, want 404 (route absent entirely) when write=false", resp.StatusCode)
	}
}

func TestHandleEnroll_NotRegisteredWhenNoEnrollSecret(t *testing.T) {
	srv, _ := newTestEnrollServer(t, true, "")
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/enroll", map[string]any{
		"name": "duppy1", "enroll_secret": "", "token": "tok", "address": "duppy1.example.com:8010",
	})
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("status = %d, want 404 (route absent entirely) when no enroll_secret is configured", resp.StatusCode)
	}
}

func TestListAndDeleteSatellites(t *testing.T) {
	srv, manager := newTestEnrollServer(t, true, "shared-secret")
	defer srv.Close()

	if err := manager.Enroll(context.Background(), satelliteFor(t, "sat1")); err != nil {
		t.Fatal(err)
	}

	listResp := doJSON(t, "GET", srv.URL+"/api/v1/proxy/satellites", nil)
	if listResp.StatusCode != http.StatusOK {
		t.Fatalf("list status = %d, want 200", listResp.StatusCode)
	}
	listBody := decodeJSON(t, listResp)
	sats, _ := listBody["satellites"].([]any)
	if len(sats) != 1 {
		t.Fatalf("expected 1 satellite listed, got %+v", listBody)
	}

	delResp := doJSON(t, "DELETE", srv.URL+"/api/v1/proxy/satellites/sat1", nil)
	if delResp.StatusCode != http.StatusOK {
		t.Fatalf("delete status = %d, want 200", delResp.StatusCode)
	}

	afterSats, err := manager.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(afterSats) != 0 {
		t.Errorf("expected no satellites after delete, got %+v", afterSats)
	}
}

func TestDeleteSatellite_RequiresWrite(t *testing.T) {
	srv, manager := newTestEnrollServer(t, false, "")
	defer srv.Close()
	if err := manager.Enroll(context.Background(), satelliteFor(t, "sat1")); err != nil {
		t.Fatal(err)
	}

	resp := doJSON(t, "DELETE", srv.URL+"/api/v1/proxy/satellites/sat1", nil)
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("status = %d, want 403 when write=false", resp.StatusCode)
	}
}

func TestSatelliteRoutes_AbsentOutsideProxyMode(t *testing.T) {
	handler := NewRESTHandler(RESTConfig{Write: true, Mode: "standalone"})
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/proxy/satellites", nil)
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("status = %d, want 404 outside proxy mode", resp.StatusCode)
	}
}
