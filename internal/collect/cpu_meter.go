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
}

// Sample reads <procRoot>/stat and returns CPU busy% (0..100) since the
// previous call. The first call only primes the meter and returns ok=false;
// ok=false is also returned on a read/parse error or a zero-length interval,
// so the caller simply skips emitting a point until a real rate exists.
func (m *CPUMeter) Sample(procRoot string) (pct float64, ok bool) {
	total, idle, err := readCPUStat(filepath.Join(procRoot, "stat"))
	if err != nil {
		return 0, false
	}
	if !m.primed {
		m.prevTotal, m.prevIdle, m.primed = total, idle, true
		return 0, false
	}
	dTotal := total - m.prevTotal
	dIdle := idle - m.prevIdle
	m.prevTotal, m.prevIdle = total, idle
	if dTotal == 0 {
		return 0, false
	}
	busy := float64(dTotal-dIdle) / float64(dTotal) * 100
	if busy < 0 {
		busy = 0
	} else if busy > 100 {
		busy = 100
	}
	return busy, true
}

// readCPUStat returns total jiffies and idle jiffies (idle + iowait, both of
// which are time the CPU wasn't doing work) from the aggregate "cpu" line.
func readCPUStat(path string) (total, idle uint64, err error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 5 || fields[0] != "cpu" {
			continue
		}
		// cpu  user nice system idle iowait irq softirq steal guest guest_nice
		for i, fld := range fields[1:] {
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
	if err := scanner.Err(); err != nil {
		return 0, 0, err
	}
	return 0, 0, fmt.Errorf("stat: no aggregate cpu line found")
}
