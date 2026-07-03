package server

import (
	"context"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

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
	s := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.0"}, nil)
	RegisterModules(s, reg, write)

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
	for _, name := range []string{"setup", "stat", "find", "slurp", "service_facts", "package_facts", "getent"} {
		if _, ok := reg.Get(name); !ok {
			t.Errorf("expected default registry to contain module %q", name)
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
