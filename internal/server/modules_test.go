package server

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// stubModule is a minimal modules.Module for exercising the write gate
// without touching the real filesystem/system tools.
type stubModule struct {
	name   string
	writes bool
}

func (s stubModule) Name() string        { return s.name }
func (s stubModule) Description() string { return "stub for testing" }
func (s stubModule) InputSchema() map[string]any {
	return map[string]any{"type": "object", "properties": map[string]any{}}
}
func (s stubModule) Writes() bool { return s.writes }
func (s stubModule) Run(ctx context.Context, params map[string]any, dryRun bool) (modules.Result, error) {
	return modules.Result{Changed: s.writes && !dryRun, Msg: "stub ran"}, nil
}

func connectModuleServer(t *testing.T, reg *modules.Registry, write bool) *mcp.ClientSession {
	t.Helper()
	return connectModuleServerWithACL(t, reg, write, nil)
}

func connectModuleServerWithACL(t *testing.T, reg *modules.Registry, write bool, acl *authz.ACL) *mcp.ClientSession {
	t.Helper()
	s := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.0"}, nil)
	RegisterModules(s, reg, write, acl, nil)

	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ctx := context.Background()
	go func() { _ = s.Run(ctx, serverTransport) }()

	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

func toolNames(t *testing.T, cs *mcp.ClientSession) map[string]bool {
	t.Helper()
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	names := map[string]bool{}
	for _, tool := range res.Tools {
		names[tool.Name] = true
	}
	return names
}

func TestRegisterModules_WriteFalseHidesWritingTools(t *testing.T) {
	reg := modules.NewRegistry()
	_ = reg.Register(stubModule{name: "read_only_stub", writes: false})
	_ = reg.Register(stubModule{name: "writing_stub", writes: true})

	cs := connectModuleServer(t, reg, false)
	names := toolNames(t, cs)

	if !names["read_only_stub"] {
		t.Error("expected read-only tool to be registered")
	}
	if names["writing_stub"] {
		t.Error("expected writing tool to be absent when write=false")
	}
}

func TestRegisterModules_WriteTrueExposesWritingTools(t *testing.T) {
	reg := modules.NewRegistry()
	_ = reg.Register(stubModule{name: "read_only_stub", writes: false})
	_ = reg.Register(stubModule{name: "writing_stub", writes: true})

	cs := connectModuleServer(t, reg, true)
	names := toolNames(t, cs)

	if !names["read_only_stub"] || !names["writing_stub"] {
		t.Errorf("expected both tools present when write=true, got %v", names)
	}
}

func TestRegisterModules_CallToolRoundTrip(t *testing.T) {
	reg := modules.NewRegistry()
	_ = reg.Register(stubModule{name: "read_only_stub", writes: false})

	cs := connectModuleServer(t, reg, false)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "read_only_stub",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %+v", res.Content)
	}
	out := res.StructuredContent.(map[string]any)
	if out["msg"] != "stub ran" {
		t.Errorf("msg = %v, want 'stub ran'", out["msg"])
	}
}

func TestNewDefaultModuleRegistry_ContainsExpectedModules(t *testing.T) {
	reg := NewDefaultModuleRegistry()
	readOnly := []string{"setup", "stat", "find", "slurp", "service_facts", "package_facts", "getent"}
	writing := []string{
		"file", "copy", "lineinfile", "systemd", "service", "apt", "command",
		"blockinfile", "replace", "assemble", "tempfile", "template",
	}
	for _, name := range append(readOnly, writing...) {
		if _, ok := reg.Get(name); !ok {
			t.Errorf("expected default registry to contain module %q", name)
		}
	}
}

func TestRegisterModules_DefaultRegistry_WriteFalseHidesWriteModules(t *testing.T) {
	reg := NewDefaultModuleRegistry()
	cs := connectModuleServer(t, reg, false)
	names := toolNames(t, cs)

	for _, name := range []string{"setup", "stat", "find", "slurp", "service_facts", "package_facts", "getent"} {
		if !names[name] {
			t.Errorf("expected read-only tool %q to be registered when write=false", name)
		}
	}
	for _, name := range []string{"file", "copy", "lineinfile", "systemd", "service", "apt", "command"} {
		if names[name] {
			t.Errorf("expected write tool %q to be absent when write=false", name)
		}
	}
}

func TestRegisterModules_DefaultRegistry_WriteTrueExposesWriteModules(t *testing.T) {
	reg := NewDefaultModuleRegistry()
	cs := connectModuleServer(t, reg, true)
	names := toolNames(t, cs)

	for _, name := range []string{"file", "copy", "lineinfile", "systemd", "service", "apt", "command"} {
		if !names[name] {
			t.Errorf("expected write tool %q to be registered when write=true", name)
		}
	}
}

func TestRegisterModules_RealStatModuleRoundTrip(t *testing.T) {
	reg := modules.NewRegistry()
	_ = reg.Register(modules.NewStat())

	cs := connectModuleServer(t, reg, false)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "stat",
		Arguments: map[string]any{"path": "/"},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %+v", res.Content)
	}
	out := res.StructuredContent.(map[string]any)
	data := out["data"].(map[string]any)
	if data["exists"] != true || data["isdir"] != true {
		t.Errorf("unexpected stat result for /: %+v", data)
	}
}

func openTestACLForModules(t *testing.T) *authz.ACL {
	t.Helper()
	acl, err := authz.OpenACL(filepath.Join(t.TempDir(), "acl.db"))
	if err != nil {
		t.Fatalf("OpenACL: %v", err)
	}
	t.Cleanup(func() { acl.Close() })
	return acl
}

func TestRegisterModules_ACLDisabledToolReturnsError(t *testing.T) {
	acl := openTestACLForModules(t)
	if err := acl.SetToolEnabled(context.Background(), "stat", false); err != nil {
		t.Fatal(err)
	}

	reg := modules.NewRegistry()
	_ = reg.Register(modules.NewStat())
	cs := connectModuleServerWithACL(t, reg, false, acl)

	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "stat",
		Arguments: map[string]any{"path": "/"},
	})
	if err != nil {
		t.Fatalf("CallTool transport error: %v", err)
	}
	if !res.IsError {
		t.Fatal("expected a disabled tool to return a tool error over MCP")
	}
}

func TestRegisterModules_ACLTokenIdentityScopedByRule(t *testing.T) {
	acl := openTestACLForModules(t)
	if _, err := acl.AddRule(context.Background(), authz.Rule{
		PrincipalKind: authz.PrincipalToken,
		PrincipalName: authz.TokenPrincipalName,
		Tools:         []string{"stat"},
	}); err != nil {
		t.Fatal(err)
	}

	reg := modules.NewRegistry()
	_ = reg.Register(modules.NewStat())
	_ = reg.Register(modules.NewCopy())
	cs := connectModuleServerWithACL(t, reg, true, acl)

	statRes, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "stat",
		Arguments: map[string]any{"path": "/"},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if statRes.IsError {
		t.Errorf("expected stat allowed by ACL rule, got error: %+v", statRes.Content)
	}

	copyRes, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "copy",
		Arguments: map[string]any{"dest": "/tmp/x", "content": "y"},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if !copyRes.IsError {
		t.Error("expected copy denied (not covered by the token's ACL rule)")
	}
}
