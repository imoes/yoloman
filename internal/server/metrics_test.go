package server

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/store"
)

func openTestMetricsStore(t *testing.T) *store.SQLiteStore {
	t.Helper()
	s, err := store.OpenSQLite(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("OpenSQLite: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func connectMetricsServer(t *testing.T, st store.Store) *mcp.ClientSession {
	t.Helper()
	s := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.0"}, nil)
	RegisterMetrics(s, st)

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

func TestMetricsQuery_ReturnsWrittenPoints(t *testing.T) {
	st := openTestMetricsStore(t)
	now := time.Now().UTC()
	if err := st.WritePoints(context.Background(), []store.Point{
		{Metric: "cpu_pct", Timestamp: now.Add(-time.Minute), Value: 42},
	}); err != nil {
		t.Fatal(err)
	}

	cs := connectMetricsServer(t, st)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "metrics_query",
		Arguments: map[string]any{"metric": "cpu_pct", "from": "1h", "to": "0s"},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %+v", res.Content)
	}
	out := res.StructuredContent.(map[string]any)
	points := out["points"].([]any)
	if len(points) != 1 {
		t.Fatalf("expected 1 point, got %d: %+v", len(points), points)
	}
	p := points[0].(map[string]any)
	if p["value"] != 42.0 {
		t.Errorf("value = %v, want 42", p["value"])
	}
}

func TestMetricsQuery_DefaultsToLastHour(t *testing.T) {
	st := openTestMetricsStore(t)
	now := time.Now().UTC()
	if err := st.WritePoints(context.Background(), []store.Point{
		{Metric: "cpu_pct", Timestamp: now.Add(-30 * time.Minute), Value: 1},
		{Metric: "cpu_pct", Timestamp: now.Add(-2 * time.Hour), Value: 2},
	}); err != nil {
		t.Fatal(err)
	}

	cs := connectMetricsServer(t, st)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "metrics_query",
		Arguments: map[string]any{"metric": "cpu_pct"},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	out := res.StructuredContent.(map[string]any)
	points := out["points"].([]any)
	if len(points) != 1 {
		t.Fatalf("expected 1 point within the default 1h window, got %d", len(points))
	}
}

func TestMetricsQuery_FiltersByLabels(t *testing.T) {
	st := openTestMetricsStore(t)
	now := time.Now().UTC()
	if err := st.WritePoints(context.Background(), []store.Point{
		{Metric: "net_bytes", Timestamp: now.Add(-time.Minute), Value: 100, Labels: map[string]string{"iface": "eth0"}},
		{Metric: "net_bytes", Timestamp: now.Add(-time.Minute), Value: 200, Labels: map[string]string{"iface": "eth1"}},
	}); err != nil {
		t.Fatal(err)
	}

	cs := connectMetricsServer(t, st)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "metrics_query",
		Arguments: map[string]any{
			"metric": "net_bytes",
			"labels": map[string]any{"iface": "eth0"},
		},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	out := res.StructuredContent.(map[string]any)
	points := out["points"].([]any)
	if len(points) != 1 {
		t.Fatalf("expected 1 filtered point, got %d", len(points))
	}
	p := points[0].(map[string]any)
	if p["value"] != 100.0 {
		t.Errorf("value = %v, want 100", p["value"])
	}
}

func TestMetricsQuery_InvalidTimeBoundRejected(t *testing.T) {
	st := openTestMetricsStore(t)
	cs := connectMetricsServer(t, st)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "metrics_query",
		Arguments: map[string]any{"metric": "cpu_pct", "from": "not-a-time"},
	})
	if err != nil {
		t.Fatalf("CallTool transport error: %v", err)
	}
	if !res.IsError {
		t.Fatal("expected an error for an invalid 'from' value")
	}
}

func TestMetricsQuery_RFC3339Bounds(t *testing.T) {
	st := openTestMetricsStore(t)
	base := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	if err := st.WritePoints(context.Background(), []store.Point{
		{Metric: "m", Timestamp: base, Value: 7},
	}); err != nil {
		t.Fatal(err)
	}

	cs := connectMetricsServer(t, st)
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name: "metrics_query",
		Arguments: map[string]any{
			"metric": "m",
			"from":   "2026-01-01T11:00:00Z",
			"to":     "2026-01-01T13:00:00Z",
		},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	out := res.StructuredContent.(map[string]any)
	points := out["points"].([]any)
	if len(points) != 1 {
		t.Fatalf("expected 1 point within explicit RFC3339 bounds, got %d", len(points))
	}
}
