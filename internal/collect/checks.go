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

// ThresholdOverride is one metric's pushed warn/crit override (Block
// L4-behavioral) — the compiled desired state's monitoring.thresholds,
// resolved by Bossman's GPO/OU precedence and pushed to the agent. A nil
// Warn/Crit means "leave the built-in default for that level". The metric
// keys the built-in checks honor are exactly the metric names the agent
// emits (so they match what an operator picks in Bossman's live metric
// search): `mem_used_pct` (Memory check, percent), `disk_used_pct` (every
// Disk <mount> check, percent), and `cpu_load5` (CPU load check — compared as
// the ABSOLUTE 5-min load rather than the per-core default that applies when
// no override is set).
type ThresholdOverride struct {
	Warn *float64
	Crit *float64
}

// effectiveThreshold returns the warn/crit to use for a metric: the pushed
// override where set, otherwise the built-in default. Also reports whether an
// override was present at all (used by the CPU check to switch from per-core
// to absolute-load comparison).
func effectiveThreshold(overrides map[string]ThresholdOverride, metric string, defWarn, defCrit float64) (warn, crit float64, overridden bool) {
	warn, crit = defWarn, defCrit
	ov, ok := overrides[metric]
	if !ok {
		return warn, crit, false
	}
	if ov.Warn != nil {
		warn = *ov.Warn
	}
	if ov.Crit != nil {
		crit = *ov.Crit
	}
	return warn, crit, true
}

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
func builtinChecks(now time.Time, load *proc.LoadAvg, cpuCount int, memUsedPct *float64, diskUsedPct map[string]float64, uptimeSeconds *float64, overrides map[string]ThresholdOverride) []CheckResult {
	var out []CheckResult

	if load != nil {
		// A `cpu_load5` override is compared against the ABSOLUTE 5-min load
		// (the metric operators see in the catalog); without one, the
		// built-in per-core default (1.0/2.0 per logical core) applies.
		warn, crit, overridden := effectiveThreshold(overrides, "cpu_load5", loadWarnPerCore, loadCritPerCore)
		var value float64
		var msg string
		if overridden {
			// Absolute 5-min load vs. the pushed load5 threshold.
			value = load.Load5
			msg = fmt.Sprintf("5min load %.2f", load.Load5)
		} else {
			// Per-core default basis (unchanged pre-L4 behavior).
			value = load.Load5
			if cpuCount > 0 {
				value = load.Load5 / float64(cpuCount)
			}
			msg = fmt.Sprintf("5min load %.2f (%.2f per core, %d cores)", load.Load5, value, cpuCount)
		}
		status := thresholdStatus(value, warn, crit)
		out = append(out, CheckResult{
			Name: "CPU load", At: now,
			Result: checks.Result{
				Status:  status,
				Message: msg,
				Perfdata: []checks.PerfDatum{
					{Label: "load1", Value: fmt.Sprintf("%.2f", load.Load1)},
					{Label: "load5", Value: fmt.Sprintf("%.2f", load.Load5)},
					{Label: "load15", Value: fmt.Sprintf("%.2f", load.Load15)},
				},
			},
		})
	}

	if memUsedPct != nil {
		warn, crit, _ := effectiveThreshold(overrides, "mem_used_pct", memWarnPct, memCritPct)
		status := thresholdStatus(*memUsedPct, warn, crit)
		out = append(out, CheckResult{
			Name: "Memory", At: now,
			Result: checks.Result{
				Status:   status,
				Message:  fmt.Sprintf("%.1f%% used", *memUsedPct),
				Perfdata: []checks.PerfDatum{{Label: "used_pct", Value: fmt.Sprintf("%.1f", *memUsedPct), Warn: fmt.Sprintf("%.0f", warn), Crit: fmt.Sprintf("%.0f", crit)}},
			},
		})
	}

	// One disk_used_pct override applies uniformly to every mount's Disk
	// check (first-cut: label-agnostic, matching the compiler's label-agnostic
	// resolution).
	diskWarn, diskCrit, _ := effectiveThreshold(overrides, "disk_used_pct", diskWarnPct, diskCritPct)
	mounts := make([]string, 0, len(diskUsedPct))
	for m := range diskUsedPct {
		mounts = append(mounts, m)
	}
	sort.Strings(mounts)
	for _, mount := range mounts {
		pct := diskUsedPct[mount]
		status := thresholdStatus(pct, diskWarn, diskCrit)
		out = append(out, CheckResult{
			Name: "Disk " + mount, At: now,
			Result: checks.Result{
				Status:   status,
				Message:  fmt.Sprintf("%.1f%% used", pct),
				Perfdata: []checks.PerfDatum{{Label: "used_pct", Value: fmt.Sprintf("%.1f", pct), Warn: fmt.Sprintf("%.0f", diskWarn), Crit: fmt.Sprintf("%.0f", diskCrit)}},
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
