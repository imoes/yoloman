package modules

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/diagnosis"
)

// RecentIncidents lists the host's recent PAST incidents — the same ring the diagnosis looks back on (OOM kills and
// fatal signals from the eBPF collector on Linux), for a timeline view (plan: the peer UX concept, item 2). READ-ONLY.
// The ring is in-memory and NOT persistent on Linux, so the answer says so and gives "since" = when this agent started;
// an absent collector is a named ring_state, not an empty list that looks like "no crashes".
type RecentIncidents struct {
	Source    func() []diagnosis.Incident // the ring's incidents (any order); nil when there is no ring
	Available func() bool                 // whether the collector is running
	Capacity  int                         // the ring's bounded size
	StartedAt time.Time                   // when this agent (and so the in-memory ring) started
	Now       func() time.Time
}

func NewRecentIncidents() *RecentIncidents { return &RecentIncidents{StartedAt: time.Now(), Now: time.Now} }

func (m *RecentIncidents) Name() string { return "recent_incidents" }

func (m *RecentIncidents) Description() string {
	return "" +
		"List the host's recent PAST incidents — the agent's incident ring (on Linux: OOM kills and fatal signals from " +
		"the eBPF collector), newest first, for a timeline. READ-ONLY. Each incident: kind (oom-kill, fatal-signal, " +
		"process-exit, image-crash, exception), time, pid, image, detail, source and a stable evidence_id (the same id " +
		"a diagnosis cites when it reports svc.recent_incident). The answer always states source, ring_state " +
		"(available | not_supported:<reason>), capacity, whether it is persistent, and 'since' (the ring is in-memory, " +
		"so incidents before the agent started are not there — an empty list after a restart is not 'no crashes').\n\n" +
		"Parameters: kind, image (filters), within_minutes (only incidents newer than this), limit (default 200).\n\n" +
		"Cross-tool equivalents: none — this is the agent's own bounded event history."
}

func (m *RecentIncidents) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"kind":           stringProp("Only this incident kind (oom-kill, fatal-signal, process-exit, image-crash, exception)."),
		"image":          stringProp("Only this process image / kernel comm."),
		"within_minutes": intProp("Only incidents from the last N minutes (0 = all that the ring holds)."),
		"limit":          intProp("At most this many, newest first (default 200)."),
	})
}

func (m *RecentIncidents) Writes() bool { return false }

func (m *RecentIncidents) Run(ctx context.Context, params map[string]any, _ bool) (Result, error) {
	kind, _ := stringParam(params, "kind", false, "")
	image, _ := stringParam(params, "image", false, "")
	within, _ := intParam(params, "within_minutes", 0)
	limit, _ := intParam(params, "limit", 200)
	if limit <= 0 {
		limit = 200
	}
	now := m.Now()
	base := map[string]any{"source": "ebpf-incident-ring", "persistent": false,
		"since": m.StartedAt.UTC().Format(time.RFC3339), "capacity": m.Capacity}

	if m.Source == nil || (m.Available != nil && !m.Available()) {
		base["ring_state"] = "not_supported: the eBPF collector is not running on this host (needs kernel >= 5.8 and CAP_BPF)"
		base["incidents"] = []any{}
		base["count"] = 0
		return Result{Changed: false, Msg: "no incident ring on this host", Data: base}, nil
	}

	all := m.Source()
	sort.SliceStable(all, func(i, j int) bool { return all[i].At.After(all[j].At) }) // newest first
	var cutoff time.Time
	if within > 0 {
		cutoff = now.Add(-time.Duration(within) * time.Minute)
	}
	imageName := commOf(image)
	out := make([]map[string]any, 0, limit)
	for _, inc := range all {
		if kind != "" && inc.Kind != kind {
			continue
		}
		if imageName != "" && commOf(inc.Image) != imageName {
			continue
		}
		if within > 0 && inc.At.Before(cutoff) {
			continue
		}
		out = append(out, incidentMap(inc))
		if len(out) >= limit {
			break
		}
	}
	base["ring_state"] = "available"
	base["incidents"] = out
	base["count"] = len(out)
	return Result{Changed: false, Msg: msgCount(len(out)), Data: base, DataSource: map[string]int{"attempts": 1, "produced": len(out)}}, nil
}

func incidentMap(i diagnosis.Incident) map[string]any {
	m := map[string]any{"kind": i.Kind, "at": i.At.UTC().Format(time.RFC3339), "pid": i.PID, "image": i.Image,
		"source": i.Source, "evidence_id": i.EvidenceID()}
	if i.Detail != "" {
		m["detail"] = i.Detail
	}
	return m
}

func msgCount(n int) string {
	if n == 0 {
		return "no incidents in the ring"
	}
	return "recent incidents listed"
}

// commOf is the kernel comm form of an image for matching: the base name, truncated to 15 chars. "" stays "".
func commOf(image string) string {
	if image == "" {
		return ""
	}
	base := image
	if i := strings.LastIndexAny(base, "/\\"); i >= 0 {
		base = base[i+1:]
	}
	if len(base) > 15 {
		base = base[:15]
	}
	return base
}
