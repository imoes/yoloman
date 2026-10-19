package modules

import (
	"context"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/diagnosis"
)

func dataOf(t *testing.T, r Result) map[string]any {
	t.Helper()
	d, ok := r.Data.(map[string]any)
	if !ok {
		t.Fatalf("Data is not a map: %T", r.Data)
	}
	return d
}

func TestRecentIncidentsNoRing(t *testing.T) {
	m := NewRecentIncidents() // no Source wired
	res, err := m.Run(context.Background(), map[string]any{}, false)
	if err != nil {
		t.Fatal(err)
	}
	d := dataOf(t, res)
	if rs, _ := d["ring_state"].(string); len(rs) < 13 || rs[:13] != "not_supported" {
		t.Fatalf("want not_supported, got %v", d["ring_state"])
	}
	if d["count"].(int) != 0 {
		t.Fatalf("want 0 incidents")
	}
}

func TestRecentIncidentsFiltersAndSorts(t *testing.T) {
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	all := []diagnosis.Incident{
		{Kind: diagnosis.IncidentOOMKill, At: now.Add(-30 * time.Minute), PID: 1, Image: "svc-a", Source: "ebpf"},
		{Kind: diagnosis.IncidentFatalSignal, At: now.Add(-2 * time.Minute), PID: 2, Image: "svc-b", Detail: "SIGSEGV", Source: "ebpf"},
		{Kind: diagnosis.IncidentOOMKill, At: now.Add(-5 * time.Minute), PID: 3, Image: "svc-a", Source: "ebpf"},
	}
	m := &RecentIncidents{Source: func() []diagnosis.Incident { return all }, Available: func() bool { return true },
		Capacity: 1000, StartedAt: now.Add(-time.Hour), Now: func() time.Time { return now }}

	d := dataOf(t, mustRun(t, m, map[string]any{}))
	inc := d["incidents"].([]map[string]any)
	if len(inc) != 3 || inc[0]["pid"].(int) != 2 {
		t.Fatalf("newest first expected (pid 2 top): %v", inc)
	}
	if d["ring_state"] != "available" || d["persistent"] != false {
		t.Fatalf("metadata: %v", d)
	}
	if dataOf(t, mustRun(t, m, map[string]any{"image": "/usr/bin/svc-a"}))["count"].(int) != 2 {
		t.Fatalf("image filter")
	}
	if dataOf(t, mustRun(t, m, map[string]any{"within_minutes": 10}))["count"].(int) != 2 {
		t.Fatalf("within filter")
	}
	if dataOf(t, mustRun(t, m, map[string]any{"kind": "oom-kill"}))["count"].(int) != 2 {
		t.Fatalf("kind filter")
	}
}

func mustRun(t *testing.T, m *RecentIncidents, p map[string]any) Result {
	t.Helper()
	r, err := m.Run(context.Background(), p, false)
	if err != nil {
		t.Fatal(err)
	}
	return r
}
