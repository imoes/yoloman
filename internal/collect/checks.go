package collect

import (
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/proc"

	"github.com/mutkluge/agentic-mcp/internal/checks"
)

// Default thresholds for the built-in checks, chosen to match common
// Nagios/CheckMK convention (load per logical core, memory/disk in
// percent) — deliberately not user-configurable in this first cut (see
// docs/plan.md's monitoring-cockpit ergänzung: "ein paar eingebaute
// Default-Checks ... damit ohne Zusatzkonfiguration sinnvolle Services
// entstehen"). Per-host overrides can be layered on later via Bossman's
// own check_rules, which already support host/group/global scoping.
const (
	loadWarnPerCore = 1.0
	loadCritPerCore = 2.0
	memWarnPct      = 80.0
	memCritPct      = 90.0
	diskWarnPct     = 80.0
	diskCritPct     = 90.0
)

// CheckResult is one named check's most recent outcome, cached in a
// CheckRegistry for GET /api/v1/hosts/overview's checks[] — kept as a
// structured Result (not just the numeric state also written to the
// store as check_<name>_state) because a Result's message/perfdata carry
// information a single float can't.
type CheckResult struct {
	Name string `json:"name"`
	checks.Result
	At time.Time `json:"at"`
}

// CheckRegistry holds the latest result of every named check (built-in or
// externally configured), thread-safe for concurrent ticker goroutines
// writing and the hosts/overview HTTP handler reading.
type CheckRegistry struct {
	mu      sync.RWMutex
	results map[string]CheckResult
}

func NewCheckRegistry() *CheckRegistry {
	return &CheckRegistry{results: map[string]CheckResult{}}
}

// Set records name's latest result, overwriting any previous one.
func (r *CheckRegistry) Set(name string, result checks.Result, at time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.results[name] = CheckResult{Name: name, Result: result, At: at}
}

// Snapshot returns every check's latest result, sorted by name for stable
// output.
func (r *CheckRegistry) Snapshot() []CheckResult {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]CheckResult, 0, len(r.results))
	for _, v := range r.results {
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func thresholdStatus(value, warn, crit float64) checks.Status {
	switch {
	case value >= crit:
		return checks.StatusCritical
	case value >= warn:
		return checks.StatusWarning
	default:
		return checks.StatusOK
	}
}

// builtinChecks derives CPU/memory/per-mount-disk/uptime checks directly
// from an already-collected sample — pure Go threshold evaluation, not an
// external plugin exec, so these exist out of the box on every host with
// no nagios-plugins package installed anywhere.
func builtinChecks(now time.Time, load *proc.LoadAvg, cpuCount int, memUsedPct *float64, diskUsedPct map[string]float64, uptimeSeconds *float64) []CheckResult {
	var out []CheckResult

	if load != nil {
		perCore := load.Load5
		if cpuCount > 0 {
			perCore = load.Load5 / float64(cpuCount)
		}
		status := thresholdStatus(perCore, loadWarnPerCore, loadCritPerCore)
		out = append(out, CheckResult{
			Name: "CPU load", At: now,
			Result: checks.Result{
				Status:  status,
				Message: fmt.Sprintf("5min load %.2f (%.2f per core, %d cores)", load.Load5, perCore, cpuCount),
				Perfdata: []checks.PerfDatum{
					{Label: "load1", Value: fmt.Sprintf("%.2f", load.Load1)},
					{Label: "load5", Value: fmt.Sprintf("%.2f", load.Load5)},
					{Label: "load15", Value: fmt.Sprintf("%.2f", load.Load15)},
				},
			},
		})
	}

	if memUsedPct != nil {
		status := thresholdStatus(*memUsedPct, memWarnPct, memCritPct)
		out = append(out, CheckResult{
			Name: "Memory", At: now,
			Result: checks.Result{
				Status:   status,
				Message:  fmt.Sprintf("%.1f%% used", *memUsedPct),
				Perfdata: []checks.PerfDatum{{Label: "used_pct", Value: fmt.Sprintf("%.1f", *memUsedPct), Warn: fmt.Sprintf("%.0f", memWarnPct), Crit: fmt.Sprintf("%.0f", memCritPct)}},
			},
		})
	}

	mounts := make([]string, 0, len(diskUsedPct))
	for m := range diskUsedPct {
		mounts = append(mounts, m)
	}
	sort.Strings(mounts)
	for _, mount := range mounts {
		pct := diskUsedPct[mount]
		status := thresholdStatus(pct, diskWarnPct, diskCritPct)
		out = append(out, CheckResult{
			Name: "Disk " + mount, At: now,
			Result: checks.Result{
				Status:   status,
				Message:  fmt.Sprintf("%.1f%% used", pct),
				Perfdata: []checks.PerfDatum{{Label: "used_pct", Value: fmt.Sprintf("%.1f", pct), Warn: fmt.Sprintf("%.0f", diskWarnPct), Crit: fmt.Sprintf("%.0f", diskCritPct)}},
			},
		})
	}

	if uptimeSeconds != nil {
		out = append(out, CheckResult{
			Name: "Uptime", At: now,
			Result: checks.Result{
				Status:   checks.StatusOK,
				Message:  fmt.Sprintf("up %.1f hours", *uptimeSeconds/3600),
				Perfdata: []checks.PerfDatum{{Label: "uptime_seconds", Value: fmt.Sprintf("%.0f", *uptimeSeconds)}},
			},
		})
	}

	return out
}
