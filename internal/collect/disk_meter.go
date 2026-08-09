package collect

import (
	"os"
	"path/filepath"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/proc"
)

// diskCounters is the per-device state the DiskIOMeter diffs between ticks.
type diskCounters struct {
	ops    uint64 // reads_completed + writes_completed
	timeMs uint64 // ms_reading + ms_writing (service time)
}

// DiskIOMeter turns the monotonically-increasing completed-I/O counters in
// /proc/diskstats into IOPS and average await (service time per I/O). Like
// CPUMeter it is stateful across ticks — it remembers the previous per-device
// counters and the time they were read, so the first Sample only primes.
type DiskIOMeter struct {
	prev   map[string]diskCounters
	prevAt time.Time
	primed bool
}

// DiskIOPS is the result of a Sample: whole-server IOPS + average await, plus
// the per-device breakdown. AwaitMs is the mean service time per I/O over the
// interval (Δservice_time / Δops), Coroot's disk "await".
type DiskIOPS struct {
	Total          float64
	AwaitMs        float64
	PerDevice      map[string]float64
	PerDeviceAwait map[string]float64
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

	names := make([]string, len(disks))
	for i, d := range disks {
		names[i] = d.Device
	}
	whole := wholeDisks(names) // whole disks only — don't double-count partitions
	cur := make(map[string]diskCounters, len(disks))
	for _, d := range disks {
		if !whole[d.Device] {
			continue
		}
		cur[d.Device] = diskCounters{
			ops:    d.ReadsCompleted + d.WritesCompleted,
			timeMs: d.MsReading + d.MsWriting,
		}
	}

	if !m.primed {
		m.prev, m.prevAt, m.primed = cur, now, true
		return DiskIOPS{}, false
	}
	dt := now.Sub(m.prevAt).Seconds()
	if dt <= 0 {
		return DiskIOPS{}, false
	}

	out := DiskIOPS{
		PerDevice:      make(map[string]float64, len(cur)),
		PerDeviceAwait: make(map[string]float64, len(cur)),
	}
	var totalOps, totalTimeMs float64
	for dev, c := range cur {
		prev, ok := m.prev[dev]
		if !ok || c.ops < prev.ops { // ignore counter resets (reboot/hotplug)
			continue
		}
		dOps := float64(c.ops - prev.ops)
		out.PerDevice[dev] = dOps / dt
		// The per-device breakdown keeps every layer — on a hypervisor the DRBD
		// and zvol devices ARE the per-VM view. The server total must not: a
		// write through drbd1000 also lands on its backing disk and is counted
		// there too, which inflated this figure (and the threshold graded
		// against it) by the whole stacked share.
		stacked := isStackedDevice(dev)
		if !stacked {
			out.Total += dOps / dt
		}
		if c.timeMs >= prev.timeMs {
			dTime := float64(c.timeMs - prev.timeMs)
			if !stacked {
				totalOps += dOps
				totalTimeMs += dTime
			}
			if dOps > 0 {
				out.PerDeviceAwait[dev] = dTime / dOps // mean ms per I/O
			}
		}
	}
	if totalOps > 0 {
		out.AwaitMs = totalTimeMs / totalOps
	}
	m.prev, m.prevAt = cur, now
	return out, true
}
