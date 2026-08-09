package collect

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/store"
)

// cgroupV2 reports whether root is mounted as the unified (v2) hierarchy —
// hoisted so both services.go and docker.go can share the one check.
func cgroupV2(root string) bool {
	_, err := os.Stat(filepath.Join(root, "cgroup.controllers"))
	return err == nil
}

// PSILine is one "some"/"full" row of a Pressure Stall Information file
// (e.g. "some avg10=0.00 avg60=0.00 avg300=0.00 total=12345").
type PSILine struct {
	Avg10, Avg60, Avg300 float64
	TotalUsec            uint64
}

// readPSI parses a cpu.pressure/memory.pressure/io.pressure file. ok=false when
// the file is missing (old kernel, PSI not compiled/enabled, cgroup v1, or the
// controller isn't delegated to this cgroup) — never an error, matching
// readUint/readKVUint's best-effort style in services.go.
func readPSI(path string) (some, full *PSILine, ok bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 2 {
			continue
		}
		line := &PSILine{}
		for _, tok := range fields[1:] {
			k, v, found := strings.Cut(tok, "=")
			if !found {
				continue
			}
			switch k {
			case "avg10":
				line.Avg10, _ = strconv.ParseFloat(v, 64)
			case "avg60":
				line.Avg60, _ = strconv.ParseFloat(v, 64)
			case "avg300":
				line.Avg300, _ = strconv.ParseFloat(v, 64)
			case "total":
				line.TotalUsec, _ = strconv.ParseUint(v, 10, 64)
			}
		}
		switch fields[0] {
		case "some":
			some, ok = line, true
		case "full":
			full, ok = line, true
		}
	}
	return some, full, ok
}

// readCPUThrottle extracts nr_periods/nr_throttled/throttled_usec from a v2
// cpu.stat file (reuses services.go's readKVUint — same file the CPU-usage
// sample already opens). ok=false if none of the throttle keys are present.
func readCPUThrottle(cpuStatPath string) (nrPeriods, nrThrottled, throttledUsec uint64, ok bool) {
	p, pOK := readKVUint(cpuStatPath, "nr_periods")
	t, tOK := readKVUint(cpuStatPath, "nr_throttled")
	u, uOK := readKVUint(cpuStatPath, "throttled_usec")
	if !pOK && !tOK && !uOK {
		return 0, 0, 0, false
	}
	return p, t, u, true
}

// readProcCgroup is overridable in tests.
var readProcCgroup = os.ReadFile

// containerCgroupPath resolves a container's cgroup v2 directory from its init
// process's host PID (Docker inspect's State.Pid) by reading /proc/<pid>/cgroup's
// "0::<path>" line — driver-independent, no path guessing. ok=false when pid<=0
// (container not running / inspect stale), the process already exited, or the
// host isn't on the unified hierarchy (no "0::" line — a v1 host has lines like
// "6:memory:/docker/<id>" instead).
func containerCgroupPath(cgroupRoot string, pid int) (string, bool) {
	if pid <= 0 {
		return "", false
	}
	data, err := readProcCgroup(fmt.Sprintf("/proc/%d/cgroup", pid))
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(string(data), "\n") {
		if rest, found := strings.CutPrefix(strings.TrimSpace(line), "0::"); found {
			return filepath.Join(cgroupRoot, rest), true
		}
	}
	return "", false
}

// psiPoints expands one some/full PSILine pair into "<prefix>_pct" (one point
// per 10s/60s/300s window) + "<prefix>_stalled_seconds_total" points, adding a
// "kind" (some|full) label to a COPY of labels (never mutates the caller's map).
// Shared by services.go and docker.go so the PSI→point shape is defined once.
func psiPoints(prefix string, labels map[string]string, now time.Time, some, full *PSILine) []store.Point {
	var out []store.Point
	add := func(kind string, l *PSILine) {
		if l == nil {
			return
		}
		for _, w := range []struct {
			window string
			val    float64
		}{{"10s", l.Avg10}, {"60s", l.Avg60}, {"300s", l.Avg300}} {
			out = append(out, store.Point{
				Metric: prefix + "_pct", Timestamp: now, Value: w.val,
				Labels: withLabels(labels, "kind", kind, "window", w.window),
			})
		}
		out = append(out, store.Point{
			Metric: prefix + "_stalled_seconds_total", Timestamp: now, Value: float64(l.TotalUsec) / 1e6,
			Labels: withLabels(labels, "kind", kind),
		})
	}
	add("some", some)
	add("full", full)
	return out
}

// withLabels returns a copy of base with the given key/value pairs added, so a
// shared base label map is never mutated across points.
func withLabels(base map[string]string, kv ...string) map[string]string {
	out := make(map[string]string, len(base)+len(kv)/2)
	for k, v := range base {
		out[k] = v
	}
	for i := 0; i+1 < len(kv); i += 2 {
		out[kv[i]] = kv[i+1]
	}
	return out
}
