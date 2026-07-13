package collect

import (
	"os"
	"path/filepath"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/proc"
)

// DiskIOMeter turns the monotonically-increasing completed-I/O counters in
// /proc/diskstats into IOPS (I/O operations per second). Like CPUMeter it is
// stateful across ticks — it remembers the previous per-device (reads+writes)
// totals and the time they were read, so the first Sample only primes.
type DiskIOMeter struct {
	prev   map[string]uint64 // physical device -> reads_completed + writes_completed
	prevAt time.Time
	primed bool
}

// DiskIOPS is the result of a Sample: the whole-server IOPS (sum over physical
// disks) plus the per-device breakdown.
type DiskIOPS struct {
	Total     float64
	PerDevice map[string]float64
}

// Sample reads <procRoot>/diskstats and returns the consumed IOPS since the
// previous Sample. ok is false on the priming call (no prior reading) or when
// diskstats can't be read.
func (m *DiskIOMeter) Sample(procRoot string, now time.Time) (DiskIOPS, bool) {
	f, err := os.Open(filepath.Join(procRoot, "diskstats"))
	if err != nil {
		return DiskIOPS{}, false
	}
	defer f.Close()
	disks, err := proc.ParseDiskStats(f)
	if err != nil {
		return DiskIOPS{}, false
	}

	cur := make(map[string]uint64, len(disks))
	for _, d := range disks {
		if !isPhysicalDisk(d.Device) {
			continue
		}
		cur[d.Device] = d.ReadsCompleted + d.WritesCompleted
	}

	if !m.primed {
		m.prev, m.prevAt, m.primed = cur, now, true
		return DiskIOPS{}, false
	}
	dt := now.Sub(m.prevAt).Seconds()
	if dt <= 0 {
		return DiskIOPS{}, false
	}

	out := DiskIOPS{PerDevice: make(map[string]float64, len(cur))}
	for dev, ops := range cur {
		if prev, ok := m.prev[dev]; ok && ops >= prev { // ignore counter resets (reboot/hotplug)
			iops := float64(ops-prev) / dt
			out.PerDevice[dev] = iops
			out.Total += iops
		}
	}
	m.prev, m.prevAt = cur, now
	return out, true
}
