//go:build ebpflive

// Live eBPF verification for the incident ring (plan E4). NOT run in CI or the normal suite — it needs a real kernel
// (>= 5.8) and root/CAP_BPF, so it is behind the `ebpflive` build tag and run deliberately:
//
//	go test -c -tags ebpflive ./internal/server      # compile as yourself
//	sudo ./server.test -test.run TestE4LiveEBPFCaptureToIncident -test.v   # run as root
//
// It proves the one piece unit tests cannot: a real signal, caught by the eBPF collector, becomes a diagnosis
// Incident through server.RecentIncidents. The rest of E4 (the comm filter, the svc.recent_incident emission) is
// covered by the ordinary Go tests.
package server

import (
	"context"
	"os/exec"
	"syscall"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/diagnosis"
	"github.com/mutkluge/agentic-mcp/internal/ebpf"
)

func TestE4LiveEBPFCaptureToIncident(t *testing.T) {
	c, err := ebpf.New(0)
	if err != nil {
		t.Fatalf("ebpf.New (need root/CAP_BPF and kernel >= 5.8): %v", err)
	}
	defer c.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go c.Run(ctx)
	time.Sleep(1500 * time.Millisecond) // let the tracepoints attach

	// A victim process with a known comm; kill it with SIGSEGV so signal:signal_generate fires for it.
	victim := exec.Command("sleep", "30")
	if err := victim.Start(); err != nil {
		t.Fatalf("start victim: %v", err)
	}
	pid := victim.Process.Pid
	time.Sleep(300 * time.Millisecond)
	if err := syscall.Kill(pid, syscall.SIGSEGV); err != nil {
		t.Fatalf("kill -SEGV %d: %v", pid, err)
	}
	_ = victim.Wait()
	time.Sleep(1500 * time.Millisecond) // let the ring-buffer event arrive

	incs := RecentIncidents(c, 500)
	t.Logf("collector returned %d incident(s)", len(incs))
	var found *diagnosis.Incident
	for i := range incs {
		if incs[i].PID == pid && incs[i].Kind == diagnosis.IncidentFatalSignal {
			found = &incs[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("no fatal-signal incident for pid %d (comm sleep); got %+v", pid, incs)
	}
	if found.Image != "sleep" || found.Detail != "SIGSEGV" || found.Source != "ebpf" {
		t.Fatalf("incident fields wrong: %+v", *found)
	}
	t.Logf("OK: %s  (evidence id %s)", found.EvidenceID(), found.EvidenceID())
}
