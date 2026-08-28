package fleet

import (
	"encoding/json"
	"sync"
	"time"
)

// MetricSample is one named, latest-value metric reading, optionally
// labeled — mirrors server.MetricSample's JSON shape exactly (redeclared
// here, not imported, to avoid a dependency from fleet on the HTTP/MCP
// server package, the same reasoning puller.go's own metricsDumpResponse
// redeclaration already documents).
type MetricSample struct {
	Metric string            `json:"metric"`
	Value  float64           `json:"value"`
	Labels map[string]string `json:"labels,omitempty"`
}

// CheckSnapshot mirrors collect.CheckResult's JSON shape (redeclared for
// the same reason as MetricSample above).
type CheckSnapshot struct {
	Name       string      `json:"name"`
	Status     string      `json:"status"`
	Message    string      `json:"message"`
	LongOutput string      `json:"long_output,omitempty"`
	Perfdata   []PerfDatum `json:"perfdata,omitempty"`
	ExitCode   int         `json:"exit_code"`
	At         time.Time   `json:"at"`
}

// PerfDatum mirrors checks.PerfDatum's JSON shape.
type PerfDatum struct {
	Label string `json:"label"`
	Value string `json:"value"`
	Warn  string `json:"warn,omitempty"`
	Crit  string `json:"crit,omitempty"`
	Min   string `json:"min,omitempty"`
	Max   string `json:"max,omitempty"`
}

// HostSnapshot mirrors server.HostSnapshot's JSON shape — one host's
// current metrics + check results, as returned by GET
// /api/v1/hosts/overview.
type HostSnapshot struct {
	Host         string          `json:"host"`
	Parent       string          `json:"parent,omitempty"`
	Mode         string          `json:"mode"`
	LastSampleAt string          `json:"last_sample_at,omitempty"`
	Metrics      []MetricSample  `json:"metrics"`
	Checks       []CheckSnapshot `json:"checks,omitempty"`
	// Inventory is passed through verbatim (the satellite's agent already
	// shaped it — see internal/inventory); RawMessage keeps this package
	// free of that dependency.
	Inventory json.RawMessage `json:"inventory,omitempty"`
}

// SnapshotCache holds the most recently pulled GET /api/v1/hosts/overview
// snapshot of every satellite a proxy polls — populated by Puller.
// PullOverviewOnce, read by this proxy's own /api/v1/hosts/overview
// handler (see docs/plan.md's monitoring-cockpit ergänzung: "der Selecta
// braucht einen Endpoint der alle Hosts mit ihren Metriken ausgibt").
// Deliberately in-memory only (not persisted to the local store): a
// satellite's snapshot is inherently a point-in-time "latest state" view,
// not a time series this proxy itself needs to retain — the proxy's own
// historical /api/v1/metrics relay (Puller.PullOnce) already covers
// graphable history.
type SnapshotCache struct {
	mu   sync.RWMutex
	byID map[string]HostSnapshot
}

func NewSnapshotCache() *SnapshotCache {
	return &SnapshotCache{byID: map[string]HostSnapshot{}}
}

// Set stores satellite's latest snapshot under satelliteName.
func (c *SnapshotCache) Set(satelliteName string, snap HostSnapshot) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.byID[satelliteName] = snap
}

// Remove drops satelliteName's cached snapshot (called when a satellite is
// un-enrolled, so a stale snapshot doesn't linger in overview responses).
func (c *SnapshotCache) Remove(satelliteName string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.byID, satelliteName)
}

// All returns every currently cached satellite snapshot.
func (c *SnapshotCache) All() []HostSnapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := make([]HostSnapshot, 0, len(c.byID))
	for _, s := range c.byID {
		out = append(out, s)
	}
	return out
}
