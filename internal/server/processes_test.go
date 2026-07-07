package server

import (
	"os"
	"testing"

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
