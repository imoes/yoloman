package server

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/proc"
)

// newTestProcRoot builds a minimal fake /proc tree with one valid line per
// parsed file, plus an outside-root symlink to exercise the proc_read guard.
func newTestProcRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()

	write := func(rel, content string) {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	write("meminfo", "MemTotal:       1000 kB\nMemFree:        500 kB\n")
	write("loadavg", "0.10 0.20 0.30 1/10 123\n")
	write("uptime", "100.5 90.5\n")
	write("cpuinfo", "processor\t: 0\nvendor_id\t: GenuineIntel\n\n")
	write("mounts", "proc /proc proc rw,nosuid 0 0\n")

	netDevHeader := "Inter-|   Receive                                                |  Transmit\n" +
		" face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
	write("net/dev", netDevHeader+
		"    lo:     100       1    0    0    0     0          0         0      100       1    0    0    0     0       0          0\n")

	write("diskstats", "   7       0 loop0 14 0 34 0 0 0 0 0 0 0 0 0 0 0 0\n")
	write("self/status", "Name:\ttest\n")

	// A file outside root that an escaping symlink might point to, to verify
	// proc_read refuses to follow it (like /proc/<pid>/exe).
	outside := filepath.Join(filepath.Dir(root), "secret-outside.txt")
	if err := os.WriteFile(outside, []byte("outside contents"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}

	return root
}

// connectTestServer registers the proc resources/tools on a fresh MCP server
// backed by procRoot, and returns a live client session connected to it over
// an in-memory transport.
func connectTestServer(t *testing.T, procRoot string) *mcp.ClientSession {
	t.Helper()
	s := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.0"}, nil)
	RegisterProc(s, procRoot)

	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ctx := context.Background()

	go func() {
		_ = s.Run(ctx, serverTransport)
	}()

	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

func TestRegisterProc_MemInfoResource(t *testing.T) {
	root := newTestProcRoot(t)
	cs := connectTestServer(t, root)

	res, err := cs.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: "proc://meminfo"})
	if err != nil {
		t.Fatalf("ReadResource: %v", err)
	}
	if len(res.Contents) != 1 {
		t.Fatalf("expected 1 content block, got %d", len(res.Contents))
	}
	var info proc.MemInfo
	if err := json.Unmarshal([]byte(res.Contents[0].Text), &info); err != nil {
		t.Fatalf("unmarshaling meminfo JSON: %v", err)
	}
	if info["MemTotal"] != 1000 {
		t.Errorf("MemTotal = %d, want 1000", info["MemTotal"])
	}
}

func TestRegisterProc_LoadAvgResource(t *testing.T) {
	root := newTestProcRoot(t)
	cs := connectTestServer(t, root)

	res, err := cs.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: "proc://loadavg"})
	if err != nil {
		t.Fatalf("ReadResource: %v", err)
	}
	var la proc.LoadAvg
	if err := json.Unmarshal([]byte(res.Contents[0].Text), &la); err != nil {
		t.Fatalf("unmarshaling loadavg JSON: %v", err)
	}
	if la.Load1 != 0.10 {
		t.Errorf("Load1 = %v, want 0.10", la.Load1)
	}
}

func TestRegisterProc_NetDevResource(t *testing.T) {
	root := newTestProcRoot(t)
	cs := connectTestServer(t, root)

	res, err := cs.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: "proc://net/dev"})
	if err != nil {
		t.Fatalf("ReadResource: %v", err)
	}
	var stats []proc.NetDevStats
	if err := json.Unmarshal([]byte(res.Contents[0].Text), &stats); err != nil {
		t.Fatalf("unmarshaling net/dev JSON: %v", err)
	}
	if len(stats) != 1 || stats[0].Interface != "lo" {
		t.Fatalf("unexpected net/dev stats: %+v", stats)
	}
}

func TestRegisterProc_UnknownResource(t *testing.T) {
	root := newTestProcRoot(t)
	cs := connectTestServer(t, root)

	if _, err := cs.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: "proc://does-not-exist"}); err == nil {
		t.Fatal("expected error reading unregistered resource")
	}
}

func TestProcReadTool_ReadsFile(t *testing.T) {
	root := newTestProcRoot(t)
	cs := connectTestServer(t, root)

	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "proc_read",
		Arguments: map[string]any{"path": "self/status"},
	})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if res.IsError {
		t.Fatalf("proc_read returned an error result: %+v", res.Content)
	}
	out, ok := res.StructuredContent.(map[string]any)
	if !ok {
		t.Fatalf("unexpected structured content type %T", res.StructuredContent)
	}
	if out["content"] != "Name:\ttest\n" {
		t.Errorf("content = %q, want %q", out["content"], "Name:\ttest\n")
	}
}

func TestProcReadTool_RejectsEscape(t *testing.T) {
	root := newTestProcRoot(t)
	cs := connectTestServer(t, root)

	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "proc_read",
		Arguments: map[string]any{"path": "escape"},
	})
	if err != nil {
		t.Fatalf("CallTool transport error: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected proc_read to report a tool error for an escaping symlink, got: %+v", res.StructuredContent)
	}
}

func TestProcReadTool_RejectsDotDotTraversal(t *testing.T) {
	root := newTestProcRoot(t)
	cs := connectTestServer(t, root)

	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{
		Name:      "proc_read",
		Arguments: map[string]any{"path": "../secret-outside.txt"},
	})
	if err != nil {
		t.Fatalf("CallTool transport error: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected proc_read to reject '..' traversal, got: %+v", res.StructuredContent)
	}
}
