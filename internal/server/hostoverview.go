package server

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/checks"
	"github.com/mutkluge/agentic-mcp/internal/fleet"
	"github.com/mutkluge/agentic-mcp/internal/piggyback"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

// MetricSample is one named, latest-value metric reading, optionally
// labeled (e.g. disk_used_pct with labels {"mount":"/"}) — the
// GET /api/v1/hosts/overview counterpart to metrics.go's MetricPoint,
// carrying only the single most recent value per series rather than a
// full history (a fleet cockpit's "latest data" table needs exactly one
// number per metric per host, not a time series — see docs/plan.md's
// monitoring-cockpit ergänzung).
type MetricSample struct {
	Metric string            `json:"metric"`
	Value  float64           `json:"value"`
	Labels map[string]string `json:"labels,omitempty"`
}

// CheckSnapshot is one check's latest result, JSON-shaped for the wire
// (collect.CheckResult itself embeds checks.Result, which already
// marshals to this same shape via Go's anonymous-field flattening — this
// type exists so fleet's mirrored HostSnapshot has something concrete to
// decode into without importing internal/collect).
type CheckSnapshot struct {
	Name       string           `json:"name"`
	Status     string           `json:"status"`
	Message    string           `json:"message"`
	LongOutput string           `json:"long_output,omitempty"`
	Perfdata   []checkPerfDatum `json:"perfdata,omitempty"`
	ExitCode   int              `json:"exit_code"`
	At         time.Time        `json:"at"`
}

type checkPerfDatum struct {
	Label string `json:"label"`
	Value string `json:"value"`
	Warn  string `json:"warn,omitempty"`
	Crit  string `json:"crit,omitempty"`
	Min   string `json:"min,omitempty"`
	Max   string `json:"max,omitempty"`
}

// HostSnapshot is one host's current metrics + check results, as returned
// by GET /api/v1/hosts/overview — this agent's own snapshot when running
// standalone/satellite, or its own snapshot plus one per currently-known
// satellite when running as a proxy, so a caller (Bossman) never needs to
// know in advance whether it's polling a leaf or a proxy: it always gets
// back a list of 1..N real hosts.
type HostSnapshot struct {
	Host         string          `json:"host"`
	Parent       string          `json:"parent,omitempty"`
	Mode         string          `json:"mode"`
	LastSampleAt string          `json:"last_sample_at,omitempty"`
	Metrics      []MetricSample  `json:"metrics"`
	Checks       []CheckSnapshot `json:"checks,omitempty"`
	// Inventory is the host's HW/SW inventory document (see
	// internal/inventory, Block H1) — typed for the self snapshot, raw
	// JSON passed through unchanged for satellites (their own agents
	// already shaped it).
	Inventory any `json:"inventory,omitempty"`
}

// HostsOverviewResponse is the GET /api/v1/hosts/overview response body.
type HostsOverviewResponse struct {
	Hosts []HostSnapshot `json:"hosts"`
}

func handleHostsOverview(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	self, err := selfSnapshot(r.Context(), cfg)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	hosts := []HostSnapshot{self}
	if cfg.Mode == "proxy" && cfg.SatelliteSnapshots != nil {
		for _, sat := range cfg.SatelliteSnapshots.All() {
			snap := HostSnapshot{
				Host:         sat.Host,
				Parent:       cfg.HostName,
				Mode:         "satellite",
				LastSampleAt: sat.LastSampleAt,
				Metrics:      convertFleetMetrics(sat.Metrics),
				Checks:       convertFleetChecks(sat.Checks),
			}
			if len(sat.Inventory) > 0 {
				snap.Inventory = sat.Inventory
			}
			hosts = append(hosts, snap)
		}
	}
	// Piggyback: report each guest (Docker container, Proxmox/vSphere VM …) as
	// its own host on behalf of this one — the CheckMK piggyback idea, ridden on
	// the existing overview distribution. Best-effort: a source that isn't
	// present is silently skipped.
	now := time.Now().UTC().Format(time.RFC3339)
	for _, col := range cfg.Piggyback {
		guests, err := col.Collect(r.Context())
		if err != nil {
			continue
		}
		for _, g := range guests {
			hosts = append(hosts, HostSnapshot{
				Host:         g.Name,
				Parent:       cfg.HostName,
				Mode:         col.Kind(),
				LastSampleAt: now,
				Metrics:      convertPiggybackMetrics(g.Metrics),
			})
		}
	}
	sort.Slice(hosts, func(i, j int) bool { return hosts[i].Host < hosts[j].Host })

	writeJSON(w, http.StatusOK, HostsOverviewResponse{Hosts: hosts})
}

// selfSnapshot builds this agent's own HostSnapshot from the local store's
// latest per-series values and cfg.CheckRegistry's latest check results.
func selfSnapshot(ctx context.Context, cfg RESTConfig) (HostSnapshot, error) {
	metrics, lastSampleAt, err := latestMetrics(ctx, cfg.Store)
	if err != nil {
		return HostSnapshot{}, fmt.Errorf("querying latest metrics: %w", err)
	}

	var checkSnaps []CheckSnapshot
	if cfg.CheckRegistry != nil {
		for _, c := range cfg.CheckRegistry.Snapshot() {
			checkSnaps = append(checkSnaps, CheckSnapshot{
				Name:       c.Name,
				Status:     string(c.Status),
				Message:    c.Message,
				LongOutput: c.LongOutput,
				Perfdata:   convertPerfdata(c.Perfdata),
				ExitCode:   c.ExitCode,
				At:         c.At,
			})
		}
	}

	snap := HostSnapshot{
		Host:    cfg.HostName,
		Mode:    cfg.Mode,
		Metrics: metrics,
		Checks:  checkSnaps,
	}
	if cfg.Inventory != nil {
		snap.Inventory = cfg.Inventory.Get()
	}
	if !lastSampleAt.IsZero() {
		snap.LastSampleAt = lastSampleAt.UTC().Format(time.RFC3339)
	}
	return snap, nil
}

// latestMetrics returns the single most recent point per distinct
// (metric, label-set) series in st, plus the newest timestamp seen across
// all of them. Mirrors metrics.go's dumpAllMetrics (same
// ListMetricNames+Query pattern) but keeps only the latest point per
// series instead of the full history — there is no dedicated "latest
// value" Store method, so this reuses the existing public interface
// rather than widening it for one caller.
func latestMetrics(ctx context.Context, st store.Store) ([]MetricSample, time.Time, error) {
	names, err := st.ListMetricNames(ctx)
	if err != nil {
		return nil, time.Time{}, err
	}

	var lastSampleAt time.Time
	var out []MetricSample
	for _, name := range names {
		points, err := st.Query(ctx, name, time.Time{}, time.Now().Add(time.Second), nil, store.ResolutionRaw)
		if err != nil {
			return nil, time.Time{}, fmt.Errorf("querying %q: %w", name, err)
		}
		latestBySeries := map[string]store.Point{}
		for _, p := range points {
			key := labelKey(p.Labels)
			if cur, ok := latestBySeries[key]; !ok || p.Timestamp.After(cur.Timestamp) {
				latestBySeries[key] = p
			}
		}
		for _, p := range latestBySeries {
			out = append(out, MetricSample{Metric: p.Metric, Value: p.Value, Labels: p.Labels})
			if p.Timestamp.After(lastSampleAt) {
				lastSampleAt = p.Timestamp
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Metric != out[j].Metric {
			return out[i].Metric < out[j].Metric
		}
		return labelKey(out[i].Labels) < labelKey(out[j].Labels)
	})
	return out, lastSampleAt, nil
}

func labelKey(labels map[string]string) string {
	if len(labels) == 0 {
		return ""
	}
	keys := make([]string, 0, len(labels))
	for k := range labels {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "%s=%s;", k, labels[k])
	}
	return b.String()
}

func convertPerfdata(in []checks.PerfDatum) []checkPerfDatum {
	if len(in) == 0 {
		return nil
	}
	out := make([]checkPerfDatum, len(in))
	for i, p := range in {
		out[i] = checkPerfDatum{Label: p.Label, Value: p.Value, Warn: p.Warn, Crit: p.Crit, Min: p.Min, Max: p.Max}
	}
	return out
}

func convertPiggybackMetrics(in []piggyback.Metric) []MetricSample {
	if len(in) == 0 {
		return nil
	}
	out := make([]MetricSample, len(in))
	for i, m := range in {
		out[i] = MetricSample{Metric: m.Name, Value: m.Value, Labels: m.Labels}
	}
	return out
}

func convertFleetMetrics(in []fleet.MetricSample) []MetricSample {
	if len(in) == 0 {
		return nil
	}
	out := make([]MetricSample, len(in))
	for i, m := range in {
		out[i] = MetricSample{Metric: m.Metric, Value: m.Value, Labels: m.Labels}
	}
	return out
}

func convertFleetChecks(in []fleet.CheckSnapshot) []CheckSnapshot {
	if len(in) == 0 {
		return nil
	}
	out := make([]CheckSnapshot, len(in))
	for i, c := range in {
		perf := make([]checkPerfDatum, len(c.Perfdata))
		for j, p := range c.Perfdata {
			perf[j] = checkPerfDatum{Label: p.Label, Value: p.Value, Warn: p.Warn, Crit: p.Crit, Min: p.Min, Max: p.Max}
		}
		out[i] = CheckSnapshot{
			Name: c.Name, Status: c.Status, Message: c.Message, LongOutput: c.LongOutput,
			Perfdata: perf, ExitCode: c.ExitCode, At: c.At,
		}
	}
	return out
}
