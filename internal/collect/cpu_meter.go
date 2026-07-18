package collect

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// CPUMeter turns the monotonically-increasing jiffy counters in /proc/stat
// into an instantaneous CPU-utilization percentage (Block C2b). A rate needs
// two readings, so the meter is stateful: it remembers the previous totals
// and reports busy% over the interval between successive Sample calls — the
// same technique `top` uses. This is emitted as the `cpu_pct` metric so
// server-side check_rules on cpu_pct finally have real data (the built-in
// "CPU load" check uses loadavg, a different signal).
type CPUMeter struct {
	prevTotal uint64
	prevIdle  uint64
	primed    bool
	// per-core previous counters, keyed by core id ("0", "1", …) — the
	// aggregate and the cores are rated over the same interval.
	prevCore map[string]cpuCounters
}

type cpuCounters struct{ total, idle uint64 }

// Sample reads <procRoot>/stat and returns aggregate CPU busy% (0..100) since
// the previous call, plus a per-core busy% map (core id → busy%). The first
// call only primes the meter and returns ok=false; ok=false is also returned on
// a read/parse error or a zero-length interval, so the caller skips emitting a
// point until a real rate exists.
func (m *CPUMeter) Sample(procRoot string) (pct float64, perCore map[string]float64, ok bool) {
	total, idle, cores, err := readCPUStat(filepath.Join(procRoot, "stat"))
	if err != nil {
		return 0, nil, false
	}
	if !m.primed {
		m.prevTotal, m.prevIdle, m.primed = total, idle, true
		m.prevCore = cores
		return 0, nil, false
	}
	dTotal := total - m.prevTotal
	dIdle := idle - m.prevIdle
	// Per-core rates against the same previous snapshot.
	perCore = make(map[string]float64, len(cores))
	for id, cur := range cores {
		if prev, seen := m.prevCore[id]; seen {
			dt := cur.total - prev.total
			if dt > 0 {
				perCore[id] = clampPct(float64(dt-(cur.idle-prev.idle)) / float64(dt) * 100)
			}
		}
	}
	m.prevTotal, m.prevIdle, m.prevCore = total, idle, cores
	if dTotal == 0 {
		return 0, perCore, false
	}
	return clampPct(float64(dTotal-dIdle) / float64(dTotal) * 100), perCore, true
}

func clampPct(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}

func sumCPUFields(fields []string) (total, idle uint64, err error) {
	// user nice system idle iowait irq softirq steal guest guest_nice
	for i, fld := range fields {
		v, perr := strconv.ParseUint(fld, 10, 64)
		if perr != nil {
			return 0, 0, fmt.Errorf("stat: cpu field %q: %w", fld, perr)
		}
		total += v
		if i == 3 || i == 4 { // idle, iowait
			idle += v
		}
	}
	return total, idle, nil
}

// readCPUStat returns aggregate total/idle jiffies (from the "cpu" line) plus a
// per-core map from the "cpuN" lines (idle = idle + iowait, both non-work time).
func readCPUStat(path string) (total, idle uint64, cores map[string]cpuCounters, err error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, nil, err
	}
	defer f.Close()
	cores = map[string]cpuCounters{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 5 || !strings.HasPrefix(fields[0], "cpu") {
			continue
		}
		t, i, perr := sumCPUFields(fields[1:])
		if perr != nil {
			return 0, 0, nil, perr
		}
		if fields[0] == "cpu" { // aggregate line
			total, idle = t, i
		} else { // "cpuN" per-core line
			cores[strings.TrimPrefix(fields[0], "cpu")] = cpuCounters{total: t, idle: i}
		}
	}
	if err := scanner.Err(); err != nil {
		return 0, 0, nil, err
	}
	if total == 0 && idle == 0 {
		return 0, 0, nil, fmt.Errorf("stat: no aggregate cpu line found")
	}
	return total, idle, cores, nil
}
