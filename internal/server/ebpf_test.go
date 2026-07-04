package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/ebpf"
)

// An empty *ebpf.Collector{} is a valid zero value (its exported methods
// only touch the in-memory event slices, not the kernel-loaded objects), so
// server-layer wiring can be tested here without root/CAP_BPF — the actual
// event-capture logic is unit-tested in internal/ebpf.
func TestRegisterEBPF_ToolsListedAndCallable(t *testing.T) {
	c := &ebpf.Collector{}
	s := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.0"}, nil)
	RegisterEBPF(s, c)

	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ctx := context.Background()
	go func() { _ = s.Run(ctx, serverTransport) }()

	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	names := toolNames(t, cs)
	for _, want := range []string{"net_connections", "top_talkers", "exec_events", "disk_io", "slow_disk_io"} {
		if !names[want] {
			t.Errorf("expected tool %q to be registered", want)
		}
	}

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "net_connections", Arguments: map[string]any{}})
	if err != nil {
		t.Fatalf("CallTool net_connections: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %+v", res.Content)
	}

	diskRes, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "disk_io", Arguments: map[string]any{}})
	if err != nil {
		t.Fatalf("CallTool disk_io: %v", err)
	}
	if diskRes.IsError {
		t.Fatalf("unexpected tool error: %+v", diskRes.Content)
	}

	slowRes, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "slow_disk_io", Arguments: map[string]any{}})
	if err != nil {
		t.Fatalf("CallTool slow_disk_io: %v", err)
	}
	if slowRes.IsError {
		t.Fatalf("unexpected tool error: %+v", slowRes.Content)
	}
}

func TestRegisterEBPFRoutes_NilCollectorMountsNothing(t *testing.T) {
	mux := http.NewServeMux()
	RegisterEBPFRoutes(mux, nil)

	srv := httptest.NewServer(mux)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/net/connections", nil)
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("status = %d, want 404 when no collector is mounted", resp.StatusCode)
	}
}

func TestRegisterEBPFRoutes_RealCollectorServesJSON(t *testing.T) {
	c := &ebpf.Collector{}
	mux := http.NewServeMux()
	RegisterEBPFRoutes(mux, c)

	srv := httptest.NewServer(mux)
	defer srv.Close()

	for _, path := range []string{"/api/v1/net/connections", "/api/v1/net/top-talkers", "/api/v1/exec-events", "/api/v1/disk-io", "/api/v1/disk-io/slowest"} {
		resp := doJSON(t, "GET", srv.URL+path, nil)
		if resp.StatusCode != http.StatusOK {
			t.Errorf("%s: status = %d, want 200", path, resp.StatusCode)
		}
	}
}

func TestLimitParam(t *testing.T) {
	cases := map[string]int{
		"": 0, "5": 5, "42": 42, "abc": 0, "-1": 0,
	}
	for query, want := range cases {
		req := httptest.NewRequest("GET", "/x?limit="+query, nil)
		if got := limitParam(req); got != want {
			t.Errorf("limitParam(%q) = %d, want %d", query, got, want)
		}
	}
}
