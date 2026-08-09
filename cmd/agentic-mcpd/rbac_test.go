package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/server"
)

// bearerRoundTripper injects a fixed Authorization header on every request
// — the test double for a real MCP client authenticating with one specific
// token, analogous to `claude mcp add ... --header "Authorization: Bearer
// <token>"`.
type bearerRoundTripper struct{ token string }

func (rt bearerRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	req.Header.Set("Authorization", "Bearer "+rt.token)
	return http.DefaultTransport.RoundTrip(req)
}

func bearerHTTPClient(token string) *http.Client {
	return &http.Client{Transport: bearerRoundTripper{token: token}}
}

// TestPerTokenRBAC_RealMCPWire is the decisive end-to-end proof for
// docs/plan.md's per-token RBAC design: two different bearer tokens,
// presented over a genuine MCP Streamable HTTP connection (not an
// in-memory transport, and not the legacy fixed-TokenIdentity path already
// covered by internal/server/modules_test.go's
// TestRegisterModules_ACLTokenIdentityScopedByRule), resolve to two
// distinct Identities and are granted two genuinely different tool scopes
// by the same ACL. Before this session's change, every MCP caller — no
// matter which token it presented — was attributed to the same fixed
// authz.TokenIdentity, so per-token ACL rules could never have had any
// effect over MCP; this test would have failed against that old code (both
// tokens would see identical access).
func TestPerTokenRBAC_RealMCPWire(t *testing.T) {
	acl, err := authz.OpenACL(filepath.Join(t.TempDir(), "acl.db"))
	if err != nil {
		t.Fatalf("OpenACL: %v", err)
	}
	t.Cleanup(func() { acl.Close() })

	ctx := context.Background()
	if _, err := acl.AddRule(ctx, authz.Rule{
		PrincipalKind: authz.PrincipalToken,
		PrincipalName: "bossman",
		Tools:         []string{"ping"},
	}); err != nil {
		t.Fatalf("AddRule: %v", err)
	}

	reg := modules.NewRegistry()
	_ = reg.Register(modules.NewPing())
	_ = reg.Register(modules.NewSetup())

	mcpServer := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.0"}, nil)
	server.RegisterModules(mcpServer, reg, false, acl, nil)

	mcpHandler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return mcpServer }, nil)
	authed := withBearerAuth("legacy-secret", []authz.TokenEntry{{Name: "bossman", Token: "bossman-secret"}}, mcpHandler)
	srv := httptest.NewServer(authed)
	t.Cleanup(srv.Close)

	callTool := func(t *testing.T, token, tool string) bool {
		t.Helper()
		client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.0"}, nil)
		cs, err := client.Connect(ctx, &mcp.StreamableClientTransport{
			Endpoint:   srv.URL,
			HTTPClient: bearerHTTPClient(token),
		}, nil)
		if err != nil {
			t.Fatalf("Connect: %v", err)
		}
		defer cs.Close()

		res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: map[string]any{}})
		if err != nil {
			t.Fatalf("CallTool(%s): %v", tool, err)
		}
		return !res.IsError
	}

	if ok := callTool(t, "bossman-secret", "ping"); !ok {
		t.Error("bossman token: expected ping allowed (covered by its ACL rule)")
	}
	if ok := callTool(t, "bossman-secret", "setup"); ok {
		t.Error("bossman token: expected setup denied (not covered by its ACL rule)")
	}
	if ok := callTool(t, "legacy-secret", "ping"); ok {
		t.Error("legacy token: expected ping denied — the ACL rule grants access to \"bossman\" only, not \"service-token\"")
	}
}
