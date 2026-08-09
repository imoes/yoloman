package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/tlsauth"
)

// generateCertPair creates a fresh ECDSA keypair and self-signed
// certificate, returning both the loadable tls.Certificate (for serving or
// presenting as a client) and the PEM-encoded PKIX public key (for writing
// out as a tls.trusted_client_keys entry).
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
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("creating certificate: %v", err)
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
	pubDER, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatalf("marshaling public key: %v", err)
	}
	pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})
	return cert, pubPEM
}

func writeKeyFile(t *testing.T, pubPEM []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "trusted.pub.pem")
	if err := os.WriteFile(path, pubPEM, 0o600); err != nil {
		t.Fatalf("writing key file: %v", err)
	}
	return path
}

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
}

func TestWithBearerAuth_CorrectTokenPasses(t *testing.T) {
	h := withBearerAuth("secret", nil, okHandler())
	req := httptest.NewRequest("GET", "/mcp", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
}

func TestWithBearerAuth_WrongTokenRejected(t *testing.T) {
	h := withBearerAuth("secret", nil, okHandler())
	req := httptest.NewRequest("GET", "/mcp", nil)
	req.Header.Set("Authorization", "Bearer wrong")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}

func TestWithBearerAuth_MissingHeaderRejected(t *testing.T) {
	h := withBearerAuth("secret", nil, okHandler())
	req := httptest.NewRequest("GET", "/mcp", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rec.Code)
	}
}

func TestWithBearerAuth_EmptyConfiguredTokenDisablesAuth(t *testing.T) {
	h := withBearerAuth("", nil, okHandler())
	req := httptest.NewRequest("GET", "/mcp", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200 (auth disabled when token is empty)", rec.Code)
	}
}

// TestWithBearerAuth_NamedTokenAttachesItsOwnIdentity proves the per-token
// RBAC wiring end to end at the middleware level: a caller presenting a
// named token (not the legacy one) gets past the gate AND the identity
// attached to the request context is that named token's own Identity —
// not the fixed authz.TokenIdentity every caller used to resolve to.
func TestWithBearerAuth_NamedTokenAttachesItsOwnIdentity(t *testing.T) {
	var gotIdentity authz.Identity
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotIdentity = authz.IdentityFromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	h := withBearerAuth("legacy-secret", []authz.TokenEntry{{Name: "bossman", Token: "bossman-secret"}}, inner)

	req := httptest.NewRequest("GET", "/mcp", nil)
	req.Header.Set("Authorization", "Bearer bossman-secret")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	want := authz.Identity{Kind: authz.KindToken, Name: "bossman"}
	if !reflect.DeepEqual(gotIdentity, want) {
		t.Errorf("identity attached to context = %+v, want %+v", gotIdentity, want)
	}
}

func TestWithBearerAuth_LegacyTokenAttachesFixedTokenIdentity(t *testing.T) {
	var gotIdentity authz.Identity
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotIdentity = authz.IdentityFromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	h := withBearerAuth("legacy-secret", []authz.TokenEntry{{Name: "bossman", Token: "bossman-secret"}}, inner)

	req := httptest.NewRequest("GET", "/mcp", nil)
	req.Header.Set("Authorization", "Bearer legacy-secret")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if !reflect.DeepEqual(gotIdentity, authz.TokenIdentity) {
		t.Errorf("identity attached to context = %+v, want authz.TokenIdentity", gotIdentity)
	}
}

// newGateTestServer starts a real HTTPS server wrapping h with
// requireTrustedClientCert, using the exact same TLS.ClientAuth setting
// production serveHTTP uses (tls.RequestClientCert, not Require) — so a
// client presenting no certificate at all still completes the handshake,
// and the 401 must come from requireTrustedClientCert's own check, not
// from the handshake itself.
func newGateTestServer(t *testing.T, serverCert tls.Certificate, h http.Handler) *httptest.Server {
	t.Helper()
	srv := httptest.NewUnstartedServer(h)
	srv.TLS = &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientAuth:   tls.RequestClientCert,
	}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv
}

func clientFor(clientCert *tls.Certificate) *http.Client {
	tlsCfg := &tls.Config{InsecureSkipVerify: true}
	if clientCert != nil {
		tlsCfg.Certificates = []tls.Certificate{*clientCert}
	}
	return &http.Client{Transport: &http.Transport{TLSClientConfig: tlsCfg}}
}

// TestRequireTrustedClientCert_DirectCallNotViaProxy proves the gate works
// for a direct caller (e.g. an MCP client, or a future Bossman connecting
// straight to an agent) — not just for the proxy/satellite puller path,
// which already has its own coverage in internal/fleet/puller_test.go.
// This is the exact mechanism cmd/agentic-mcpd/http.go's serveHTTP wires
// onto /mcp and /api/v1/ whenever tls.trusted_client_keys is configured.
func TestRequireTrustedClientCert_DirectCallNotViaProxy(t *testing.T) {
	serverCert, _ := generateCertPair(t, "agent")
	clientCert, clientPubPEM := generateCertPair(t, "bossman")
	trustedKey, err := tlsauth.LoadTrustedKey("bossman", writeKeyFile(t, clientPubPEM))
	if err != nil {
		t.Fatalf("LoadTrustedKey: %v", err)
	}

	h := requireTrustedClientCert([]tlsauth.TrustedKey{trustedKey}, okHandler())
	srv := newGateTestServer(t, serverCert, h)

	resp, err := clientFor(&clientCert).Get(srv.URL + "/mcp")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200 for a directly-connecting caller presenting a trusted client cert", resp.StatusCode)
	}
}

func TestRequireTrustedClientCert_NoCertRejected(t *testing.T) {
	serverCert, _ := generateCertPair(t, "agent")
	_, clientPubPEM := generateCertPair(t, "bossman")
	trustedKey, err := tlsauth.LoadTrustedKey("bossman", writeKeyFile(t, clientPubPEM))
	if err != nil {
		t.Fatalf("LoadTrustedKey: %v", err)
	}

	h := requireTrustedClientCert([]tlsauth.TrustedKey{trustedKey}, okHandler())
	srv := newGateTestServer(t, serverCert, h)

	resp, err := clientFor(nil).Get(srv.URL + "/api/v1/tools/ping")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401 when no client certificate is presented", resp.StatusCode)
	}
}

func TestRequireTrustedClientCert_UntrustedCertRejected(t *testing.T) {
	serverCert, _ := generateCertPair(t, "agent")
	untrustedClientCert, _ := generateCertPair(t, "attacker")
	_, otherPubPEM := generateCertPair(t, "bossman")
	trustedKey, err := tlsauth.LoadTrustedKey("bossman", writeKeyFile(t, otherPubPEM))
	if err != nil {
		t.Fatalf("LoadTrustedKey: %v", err)
	}

	h := requireTrustedClientCert([]tlsauth.TrustedKey{trustedKey}, okHandler())
	srv := newGateTestServer(t, serverCert, h)

	resp, err := clientFor(&untrustedClientCert).Get(srv.URL + "/mcp")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401 for a client certificate not in the trusted list", resp.StatusCode)
	}
}

// TestGates_ComposeAsDefenseInDepth mirrors serveHTTP's exact composition
// (bearer auth wrapped, then the trusted-cert gate wrapped around that) and
// proves both are required independently: a caller must present both the
// correct token AND a trusted certificate — either alone is insufficient.
func TestGates_ComposeAsDefenseInDepth(t *testing.T) {
	serverCert, _ := generateCertPair(t, "agent")
	clientCert, clientPubPEM := generateCertPair(t, "bossman")
	trustedKey, err := tlsauth.LoadTrustedKey("bossman", writeKeyFile(t, clientPubPEM))
	if err != nil {
		t.Fatalf("LoadTrustedKey: %v", err)
	}

	composed := requireTrustedClientCert([]tlsauth.TrustedKey{trustedKey}, withBearerAuth("secret", nil, okHandler()))
	srv := newGateTestServer(t, serverCert, composed)

	get := func(client *http.Client, token string) int {
		req, err := http.NewRequest("GET", srv.URL+"/api/v1/tools/ping", nil)
		if err != nil {
			t.Fatalf("NewRequest: %v", err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("Do: %v", err)
		}
		defer resp.Body.Close()
		return resp.StatusCode
	}

	if got := get(clientFor(&clientCert), "secret"); got != http.StatusOK {
		t.Errorf("trusted cert + correct token: status = %d, want 200", got)
	}
	if got := get(clientFor(&clientCert), "wrong"); got != http.StatusUnauthorized {
		t.Errorf("trusted cert + wrong token: status = %d, want 401", got)
	}
	if got := get(clientFor(nil), "secret"); got != http.StatusUnauthorized {
		t.Errorf("no cert + correct token: status = %d, want 401", got)
	}
}

func TestLoadTrustedClientKeys_SkipsBrokenEntriesGracefully(t *testing.T) {
	_, goodPubPEM := generateCertPair(t, "good")
	goodPath := writeKeyFile(t, goodPubPEM)

	keys := loadTrustedClientKeys([]config.TrustedClientKey{
		{Name: "good", PublicKeyPath: goodPath},
		{Name: "broken", PublicKeyPath: "/no/such/file.pem"},
	})
	if len(keys) != 1 {
		t.Fatalf("expected exactly 1 loaded key (broken entry skipped), got %d", len(keys))
	}
	if keys[0].Name != "good" {
		t.Errorf("loaded key name = %q, want good", keys[0].Name)
	}
}
