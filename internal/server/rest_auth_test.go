package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

func contextBG() context.Context   { return context.Background() }
func bytesBody(s string) io.Reader { return strings.NewReader(s) }

// newAuthTestServer builds a REST server with a real bearer token, a real
// SQLite-backed ACL store, a session store, and a PAM authenticator backed
// by a throwaway pam_permit/pam_deny service (see internal/authz tests) —
// exercising the full auth stack, not stubs.
func newAuthTestServer(t *testing.T, allowLogin bool) (*httptest.Server, *authz.ACL, string) {
	t.Helper()
	st, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })

	acl, err := authz.OpenACL(filepath.Join(t.TempDir(), "acl.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { acl.Close() })

	confDir := t.TempDir()
	serviceName := "agentic-test-permit"
	if !allowLogin {
		serviceName = "agentic-test-deny"
	}
	pamContent := "auth required pam_permit.so\naccount required pam_permit.so\n"
	if !allowLogin {
		pamContent = "auth required pam_deny.so\naccount required pam_deny.so\n"
	}
	if err := os.WriteFile(filepath.Join(confDir, serviceName), []byte(pamContent), 0o644); err != nil {
		t.Fatal(err)
	}

	lookupGroups := func(username string) ([]string, error) { return []string{"testgroup"}, nil }
	// Wrapped exactly as the daemon wires it (authz.NewPasswordLogin): the group requirement in front of the
	// password backend. Testing the bare backend would leave the shape the daemon actually serves untested.
	passwordAuth := &authz.GroupRequired{
		Inner:        &authz.PAMAuthenticator{Service: serviceName, ConfDir: confDir, LookupGroups: lookupGroups},
		Group:        "testgroup",
		LookupGroups: lookupGroups,
	}

	modReg := modules.NewRegistry()
	_ = modReg.Register(modules.NewStat())
	_ = modReg.Register(modules.NewCopy())

	const token = "test-token-123"
	handler := NewRESTHandler(RESTConfig{
		ProcRoot:     "/proc",
		ModReg:       modReg,
		Policy:       pipeline.EmptyPolicy(),
		Store:        st,
		Write:        true,
		Token:        token,
		ACL:          acl,
		Sessions:     authz.NewSessionStore(time.Hour),
		PasswordAuth: passwordAuth,
	})
	return httptest.NewServer(handler), acl, token
}

func TestREST_RequiresAuthWhenTokenConfigured(t *testing.T) {
	srv, _, _ := newAuthTestServer(t, true)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/proc", nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401 with no credentials", resp.StatusCode)
	}
}

func TestREST_AcceptsBearerToken(t *testing.T) {
	srv, _, token := newAuthTestServer(t, true)
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/proc", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200 with valid bearer token", resp.StatusCode)
	}
}

func TestREST_RejectsWrongBearerToken(t *testing.T) {
	srv, _, _ := newAuthTestServer(t, true)
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/proc", nil)
	req.Header.Set("Authorization", "Bearer wrong-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401 with wrong token", resp.StatusCode)
	}
}

func TestREST_LoginSuccessThenSessionAuthenticates(t *testing.T) {
	srv, _, _ := newAuthTestServer(t, true)
	defer srv.Close()

	loginResp := doJSON(t, "POST", srv.URL+"/api/v1/auth/login", map[string]string{
		"username": "alice", "password": "anything",
	})
	if loginResp.StatusCode != http.StatusOK {
		t.Fatalf("login status = %d", loginResp.StatusCode)
	}
	var loginOut struct {
		SessionToken string `json:"session_token"`
	}
	if err := json.NewDecoder(loginResp.Body).Decode(&loginOut); err != nil {
		t.Fatal(err)
	}
	if loginOut.SessionToken == "" {
		t.Fatal("expected a non-empty session token")
	}

	req, _ := http.NewRequest("GET", srv.URL+"/api/v1/proc", nil)
	req.Header.Set("Authorization", "Session "+loginOut.SessionToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200 with a valid session token", resp.StatusCode)
	}
}

func TestREST_LoginFailureRejected(t *testing.T) {
	srv, _, _ := newAuthTestServer(t, false) // PAM configured to deny
	defer srv.Close()

	resp := doJSON(t, "POST", srv.URL+"/api/v1/auth/login", map[string]string{
		"username": "alice", "password": "wrong",
	})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401 for failed PAM login", resp.StatusCode)
	}
}

func TestREST_ACL_DisabledToolReturns403(t *testing.T) {
	srv, acl, token := newAuthTestServer(t, true)
	defer srv.Close()

	if err := acl.SetToolEnabled(contextBG(), "stat", false); err != nil {
		t.Fatal(err)
	}

	req, _ := http.NewRequest("POST", srv.URL+"/api/v1/tools/stat", bytesBody(`{"path":"/"}`))
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("status = %d, want 403 for a disabled tool", resp.StatusCode)
	}
}

func TestREST_ACL_TokenIdentityScopedByRule(t *testing.T) {
	srv, acl, token := newAuthTestServer(t, true)
	defer srv.Close()

	if _, err := acl.AddRule(contextBG(), authz.Rule{
		PrincipalKind: authz.PrincipalToken,
		PrincipalName: authz.TokenPrincipalName,
		Tools:         []string{"stat"},
		AllowWrite:    false,
	}); err != nil {
		t.Fatal(err)
	}

	statReq, _ := http.NewRequest("POST", srv.URL+"/api/v1/tools/stat", bytesBody(`{"path":"/"}`))
	statReq.Header.Set("Authorization", "Bearer "+token)
	statResp, err := http.DefaultClient.Do(statReq)
	if err != nil {
		t.Fatal(err)
	}
	if statResp.StatusCode != http.StatusOK {
		t.Errorf("stat status = %d, want 200 (covered by rule)", statResp.StatusCode)
	}

	copyReq, _ := http.NewRequest("POST", srv.URL+"/api/v1/tools/copy", bytesBody(`{"dest":"/tmp/x","content":"y"}`))
	copyReq.Header.Set("Authorization", "Bearer "+token)
	copyResp, err := http.DefaultClient.Do(copyReq)
	if err != nil {
		t.Fatal(err)
	}
	if copyResp.StatusCode != http.StatusForbidden {
		t.Errorf("copy status = %d, want 403 (not covered by rule, default-deny once rules exist)", copyResp.StatusCode)
	}
}

func TestREST_ACL_ToolStateEndpoints(t *testing.T) {
	srv, _, token := newAuthTestServer(t, true)
	defer srv.Close()

	getReq, _ := http.NewRequest("GET", srv.URL+"/api/v1/acl/tools/stat", nil)
	getReq.Header.Set("Authorization", "Bearer "+token)
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatal(err)
	}
	var getOut map[string]any
	json.NewDecoder(getResp.Body).Decode(&getOut)
	if getOut["enabled"] != true {
		t.Errorf("expected enabled=true by default, got %v", getOut)
	}

	patchReq, _ := http.NewRequest("PATCH", srv.URL+"/api/v1/acl/tools/stat", bytesBody(`{"enabled":false}`))
	patchReq.Header.Set("Authorization", "Bearer "+token)
	patchResp, err := http.DefaultClient.Do(patchReq)
	if err != nil {
		t.Fatal(err)
	}
	if patchResp.StatusCode != http.StatusOK {
		t.Fatalf("PATCH status = %d", patchResp.StatusCode)
	}

	getReq2, _ := http.NewRequest("GET", srv.URL+"/api/v1/acl/tools/stat", nil)
	getReq2.Header.Set("Authorization", "Bearer "+token)
	getResp2, _ := http.DefaultClient.Do(getReq2)
	var getOut2 map[string]any
	json.NewDecoder(getResp2.Body).Decode(&getOut2)
	if getOut2["enabled"] != false {
		t.Errorf("expected enabled=false after PATCH, got %v", getOut2)
	}
}

func TestREST_ACL_RulesEndpoints(t *testing.T) {
	srv, _, token := newAuthTestServer(t, true)
	defer srv.Close()

	putReq, _ := http.NewRequest("PUT", srv.URL+"/api/v1/acl/rules", bytesBody(`{"rules":[
		{"principal_kind":"group","principal_name":"wheel","allow_write":true}
	]}`))
	putReq.Header.Set("Authorization", "Bearer "+token)
	putResp, err := http.DefaultClient.Do(putReq)
	if err != nil {
		t.Fatal(err)
	}
	if putResp.StatusCode != http.StatusOK {
		t.Fatalf("PUT status = %d", putResp.StatusCode)
	}

	getReq, _ := http.NewRequest("GET", srv.URL+"/api/v1/acl/rules", nil)
	getReq.Header.Set("Authorization", "Bearer "+token)
	getResp, err := http.DefaultClient.Do(getReq)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	json.NewDecoder(getResp.Body).Decode(&out)
	rules := out["rules"].([]any)
	if len(rules) != 1 {
		t.Fatalf("expected 1 rule after PUT, got %d: %+v", len(rules), rules)
	}
}

func TestREST_AuthMethodsAnnouncesWhatThisHostCanDo(t *testing.T) {
	srv, _, _ := newAuthTestServer(t, true)
	defer srv.Close()

	// Unauthenticated on purpose: it is asked BEFORE anyone has credentials, like /auth/login itself.
	resp := doJSON(t, "GET", srv.URL+"/api/v1/auth/methods", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 without credentials", resp.StatusCode)
	}
	var out struct {
		Password bool   `json:"password"`
		Token    bool   `json:"token"`
		Group    string `json:"group"`
		Reason   string `json:"password_unavailable_reason"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if !out.Password || !out.Token {
		t.Errorf("password=%v token=%v, want both available on this server", out.Password, out.Token)
	}
	// The required group is named, so a member-less user is told WHY the right password was refused instead of
	// being left with "login failed".
	if out.Group != "testgroup" {
		t.Errorf("group = %q, want the group the login actually requires", out.Group)
	}
	if out.Reason != "" {
		t.Errorf("reason = %q, want none while password login works", out.Reason)
	}
}

func TestREST_AuthMethodsNamesWhyPasswordLoginIsAbsent(t *testing.T) {
	// A host with no password backend at all: the honest answer is "no", with the reason — not a form.
	handler := NewRESTHandler(RESTConfig{ProcRoot: "/proc", Policy: pipeline.EmptyPolicy(), Token: "t",
		Sessions: authz.NewSessionStore(time.Hour)})
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/auth/methods", nil)
	var out struct {
		Password bool   `json:"password"`
		Reason   string `json:"password_unavailable_reason"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Password {
		t.Error("password login must not be advertised without a backend")
	}
	if out.Reason == "" {
		t.Error("an unavailable login must state its reason; the operator's fix depends on which one it is")
	}

	// And the endpoint must agree with the endpoint it describes: 503, not a 401 that reads like bad credentials.
	login := doJSON(t, "POST", srv.URL+"/api/v1/auth/login", map[string]string{"username": "a", "password": "b"})
	if login.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("login status = %d, want 503 when there is no backend at all", login.StatusCode)
	}
}
