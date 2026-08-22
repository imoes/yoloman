package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/ebpf"
)

func TestExecContainerByPID(t *testing.T) {
	execs := []ebpf.ExecEvent{
		{PID: 10, Comm: "sh", ContainerID: ""}, // no container → skipped
		{PID: 20, Comm: "nginx", ContainerID: "abc123"},
		{PID: 20, Comm: "nginx", ContainerID: "def456"}, // newer wins on pid reuse
	}
	m := execContainerByPID(execs)
	if _, ok := m[10]; ok {
		t.Errorf("pid 10 has no container id, should be absent")
	}
	if m[20] != "def456" {
		t.Errorf("pid 20 = %q, want def456 (newest)", m[20])
	}
}

func TestSystemdUnitForPID(t *testing.T) {
	root := t.TempDir()
	write := func(pid, cgroup string) {
		dir := root + "/" + pid
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(dir+"/cgroup", []byte(cgroup), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("1", "0::/system.slice/sshd.service\n")
	write("2", "0::/system.slice/system-getty.slice/getty@tty1.service\n")                   // nested slice
	write("3", "0::/user.slice/user-1000.slice/session-3.scope\n")                           // not a service
	write("4", "0::/system.slice/docker-abc.scope\n")                                        // container scope, not a service
	write("5", "12:pids:/system.slice/cron.service\n11:memory:/system.slice/cron.service\n") // v1 layout

	cases := map[string]string{"1": "sshd", "2": "getty@tty1", "3": "", "4": "", "5": "cron"}
	for pid, want := range cases {
		p, _ := strconv.Atoi(pid)
		if got := systemdUnitForPID(root, p); got != want {
			t.Errorf("pid %s: got %q, want %q", pid, got, want)
		}
	}
	// A pid with no cgroup file → "".
	if got := systemdUnitForPID(root, 9999); got != "" {
		t.Errorf("missing pid: got %q, want empty", got)
	}
}

func TestEstablishedConnsByPID(t *testing.T) {
	conns := []ebpf.TCPConnEvent{
		{PID: 5, DstAddr: "10.0.0.1", DstPort: 443, NewState: "ESTABLISHED"},
		{PID: 5, DstAddr: "10.0.0.1", DstPort: 443, NewState: "ESTABLISHED"}, // dup → collapsed
		{PID: 5, DstAddr: "10.0.0.2", DstPort: 5432, NewState: "ESTABLISHED"},
		{PID: 5, DstAddr: "10.0.0.9", DstPort: 22, NewState: "SYN_SENT"}, // not established → ignored
	}
	m := establishedConnsByPID(conns)
	if len(m[5]) != 2 {
		t.Fatalf("pid 5 conns = %d, want 2 (deduped, established-only)", len(m[5]))
	}
	ports := map[uint16]bool{}
	for _, c := range m[5] {
		ports[c.DstPort] = true
	}
	if !ports[443] || !ports[5432] {
		t.Errorf("expected ports 443 and 5432, got %v", ports)
	}
	if ports[22] {
		t.Errorf("SYN_SENT connection should not be included")
	}
}

func TestCollectProcessesWithoutEBPF(t *testing.T) {
	if _, err := os.Stat("/proc/self/stat"); err != nil {
		t.Skip("no /proc on this platform")
	}
	resp, err := collectProcesses("/proc", nil, 5)
	if err != nil {
		t.Fatalf("collectProcesses: %v", err)
	}
	if resp.Count < 1 {
		t.Fatal("expected at least one process")
	}
	if len(resp.Processes) > 5 {
		t.Errorf("limit=5 returned %d processes", len(resp.Processes))
	}
	if resp.Count >= 5 && len(resp.Processes) != 5 {
		t.Errorf("with %d total and limit 5, want 5 returned, got %d", resp.Count, len(resp.Processes))
	}
	if resp.SampleWindowMS <= 0 {
		t.Errorf("SampleWindowMS = %d, want > 0", resp.SampleWindowMS)
	}
	// No eBPF → no enrichment.
	for _, p := range resp.Processes {
		if p.ContainerID != "" || p.Connections != nil {
			t.Errorf("pid %d has enrichment without an eBPF collector", p.PID)
		}
	}
}

func TestRegisterProcessRoutes_ServesJSON(t *testing.T) {
	if _, err := os.Stat("/proc/self/stat"); err != nil {
		t.Skip("no /proc on this platform")
	}
	mux := http.NewServeMux()
	RegisterProcessRoutes(mux, RESTConfig{ProcRoot: "/proc", EBPF: &ebpf.Collector{}})

	srv := httptest.NewServer(mux)
	defer srv.Close()

	resp := doJSON(t, "GET", srv.URL+"/api/v1/processes?limit=3", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var body ProcessesResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	resp.Body.Close()
	if body.Count < 1 {
		t.Errorf("Count = %d, want >= 1", body.Count)
	}
	if len(body.Processes) > 3 {
		t.Errorf("limit=3 returned %d", len(body.Processes))
	}
	if body.SampleWindowMS <= 0 {
		t.Errorf("SampleWindowMS = %d, want > 0", body.SampleWindowMS)
	}
}

func TestRegisterProcessList_ToolCallable(t *testing.T) {
	if _, err := os.Stat("/proc/self/stat"); err != nil {
		t.Skip("no /proc on this platform")
	}
	s := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "0.0.0"}, nil)
	RegisterProcessList(s, "/proc", &ebpf.Collector{})

	serverTransport, clientTransport := mcp.NewInMemoryTransports()
	ctx := context.Background()
	go func() { _ = s.Run(ctx, serverTransport) }()

	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "0.0.0"}, nil)
	cs, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer cs.Close()

	if names := toolNames(t, cs); !names["process_list"] {
		t.Fatal("expected process_list tool to be registered")
	}
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "process_list", Arguments: map[string]any{"limit": 2}})
	if err != nil {
		t.Fatalf("CallTool process_list: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected tool error: %+v", res.Content)
	}
}
