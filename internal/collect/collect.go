// Package collect periodically samples this host's own OS-level metrics
// (CPU load, memory, disk, uptime, network) and derives a handful of
// built-in health checks from them — the metric-collection foundation that
// was previously entirely missing from agentic-mcpd: before this package,
// the only point the daemon ever wrote to its own store was a one-shot
// "agentic_mcpd_start" marker (see cmd/agentic-mcpd/main.go's
// recordStartupMarker), so a fleet cockpit polling this agent had no real
// CPU/RAM/disk data to show (see docs/plan.md's monitoring-cockpit
// ergänzung). Sample reuses the existing internal/proc parsers rather than
// reading /proc a second, different way.
package collect

import (
	"fmt"
	"io"
	"strings"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/checks"
	"github.com/mutkluge/agentic-mcp/internal/proc"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

// Snapshot is one round of collected host state: the raw metric points to
// persist (for historical graphing, exactly like every other metric in
// this project) and the derived built-in check results (CPU/memory/disk/
// uptime) to serve on GET /api/v1/hosts/overview without a caller having
// to know which metric names compose "is this host healthy".
type Snapshot struct {
	Points []store.Point
	Checks []CheckResult
}

// statfsFunc abstracts the disk-usage syscall for testability (mirrors
// internal/checks.ExecFunc's injection pattern) — a real mount point is
// needed for a genuine statfs(2) call, which a /proc fixture file cannot
// provide.
type statfsFunc func(mountPoint string) (usedPct float64, totalBytes, usedBytes uint64, err error)

// realFilesystems is an allow-list of on-disk filesystem types worth
// reporting disk usage for. Everything else (proc, sysfs, tmpfs, cgroup,
// overlay, ...) is a pseudo/virtual filesystem — on a Docker host like the
// ones this project targets, /proc/mounts lists dozens of per-container
// "overlay" mounts under /var/lib/docker that would otherwise flood every
// sample with noise no operator wants graphed.
var realFilesystems = map[string]bool{
	"ext2": true, "ext3": true, "ext4": true,
	"xfs": true, "btrfs": true, "zfs": true,
	"vfat": true, "exfat": true, "ntfs": true,
	"f2fs": true, "jfs": true, "reiserfs": true,
}

// isPhysicalDisk filters /proc/diskstats down to real block devices, dropping
// loopback/ramdisk/floppy noise no operator wants graphed.
func isPhysicalDisk(device string) bool {
	for _, prefix := range []string{"loop", "ram", "fd", "sr", "dm-"} {
		if strings.HasPrefix(device, prefix) {
			return false
		}
	}
	return true
}

// wholeDisks returns the set of whole block devices among `devices`, excluding
// partitions — a device is a partition when another listed device is a strict
// prefix of it (sda1 of sda, nvme0n1p1 of nvme0n1). Summing per-partition and
// whole-disk I/O would otherwise double-count a server's total.
func wholeDisks(devices []string) map[string]bool {
	phys := make([]string, 0, len(devices))
	for _, d := range devices {
		if isPhysicalDisk(d) {
			phys = append(phys, d)
		}
	}
	out := make(map[string]bool, len(phys))
	for _, d := range phys {
		isPart := false
		for _, other := range phys {
			if other != d && strings.HasPrefix(d, other) {
				isPart = true
				break
			}
		}
		if !isPart {
			out[d] = true
		}
	}
	return out
}

// Sample reads /proc under procRoot once, at timestamp now, and returns the
// canonical set of OS metrics plus derived built-in check results. statfs
// is called once per real (non-virtual, deduplicated-by-device) mount
// point found in /proc/mounts.
func Sample(procRoot string, now time.Time, statfs statfsFunc, overrides map[string]ThresholdOverride) (Snapshot, error) {
	var points []store.Point
	add := func(metric string, value float64, labels map[string]string) {
		points = append(points, store.Point{Metric: metric, Timestamp: now, Value: value, Labels: labels})
	}

	var load *proc.LoadAvg
	if la, err := parseProcFile(procRoot, "loadavg", proc.ParseLoadAvg); err == nil {
		load = &la
		add("cpu_load1", la.Load1, nil)
		add("cpu_load5", la.Load5, nil)
		add("cpu_load15", la.Load15, nil)
	}

	var cpuCount int
	if cpus, err := parseProcFile(procRoot, "cpuinfo", proc.ParseCPUInfo); err == nil {
		cpuCount = len(cpus)
		add("cpu_count", float64(cpuCount), nil)
	}

	var memUsedPct *float64
	if mem, err := parseProcFile(procRoot, "meminfo", proc.ParseMemInfo); err == nil {
		if totalKB, ok := mem["MemTotal"]; ok && totalKB > 0 {
			availKB := mem["MemAvailable"] // 0 if absent (very old kernels) — usedPct would then read 100%, acceptable degradation
			usedKB := totalKB - availKB
			pct := float64(usedKB) / float64(totalKB) * 100
			memUsedPct = &pct
			add("mem_total_bytes", float64(totalKB)*1024, nil)
			add("mem_used_bytes", float64(usedKB)*1024, nil)
			add("mem_used_pct", pct, nil)
			// Coroot-style memory breakdown (available/free/cached) for a
			// stacked node memory chart.
			add("mem_available_bytes", float64(availKB)*1024, nil)
			add("mem_free_bytes", float64(mem["MemFree"])*1024, nil)
			add("mem_cached_bytes", float64(mem["Cached"])*1024, nil)
		}
	}

	// CPU by mode (Coroot node_resources_cpu_usage_seconds_total): per-mode
	// cumulative seconds as counters; Bossman derives per-mode utilization.
	if modes, err := parseProcFile(procRoot, "stat", proc.ParseStatCPUModes); err == nil {
		for mode, secs := range modes {
			add("cpu_mode_seconds_total", secs, map[string]string{"mode": mode})
		}
	}

	// Per-device disk I/O counters (Coroot node_resources_disk_*): reads/writes,
	// bytes (sectors×512), and service time in ms. Bossman derives IOPS, await
	// (=(read+write time)/(read+write ops)), and bandwidth from the rates.
	if disks, err := parseProcFile(procRoot, "diskstats", proc.ParseDiskStats); err == nil {
		names := make([]string, len(disks))
		for i, d := range disks {
			names[i] = d.Device
		}
		whole := wholeDisks(names)
		for _, d := range disks {
			if !whole[d.Device] || (d.ReadsCompleted == 0 && d.WritesCompleted == 0) {
				continue
			}
			labels := map[string]string{"device": d.Device}
			add("disk_reads_total", float64(d.ReadsCompleted), labels)
			add("disk_writes_total", float64(d.WritesCompleted), labels)
			add("disk_read_bytes_total", float64(d.SectorsRead)*512, labels)
			add("disk_written_bytes_total", float64(d.SectorsWritten)*512, labels)
			add("disk_read_time_ms_total", float64(d.MsReading), labels)
			add("disk_write_time_ms_total", float64(d.MsWriting), labels)
		}
	}

	var uptimeSeconds *float64
	if up, err := parseProcFile(procRoot, "uptime", proc.ParseUptime); err == nil {
		uptimeSeconds = &up.UptimeSeconds
		add("uptime_seconds", up.UptimeSeconds, nil)
	}

	diskUsedPct := map[string]float64{} // mount -> used pct, for the built-in per-mount disk check
	if mounts, err := parseProcFile(procRoot, "mounts", proc.ParseMounts); err == nil {
		for _, m := range dedupeRealMounts(mounts) {
			pct, total, used, serr := statfs(m.MountPoint)
			if serr != nil || total == 0 {
				continue
			}
			labels := map[string]string{"mount": m.MountPoint}
			add("disk_total_bytes", float64(total), labels)
			add("disk_used_bytes", float64(used), labels)
			add("disk_used_pct", pct, labels)
			diskUsedPct[m.MountPoint] = pct
		}
	}

	if ifaces, err := parseProcFile(procRoot, "net/dev", proc.ParseNetDev); err == nil {
		for _, s := range ifaces {
			if s.Interface == "lo" {
				continue
			}
			labels := map[string]string{"iface": s.Interface}
			add("net_rx_bytes", float64(s.RxBytes), labels)
			add("net_tx_bytes", float64(s.TxBytes), labels)
		}
	}

	return Snapshot{
		Points: points,
		Checks: builtinChecks(now, load, cpuCount, memUsedPct, diskUsedPct, uptimeSeconds, overrides),
	}, nil
}

// SampleDefault is Sample backed by the real statfs(2) syscall — the
// non-test entry point (mirrors internal/checks.RunDefault). `overrides` are
// the pushed desired-state thresholds (nil/empty = built-in defaults).
func SampleDefault(procRoot string, now time.Time, overrides map[string]ThresholdOverride) (Snapshot, error) {
	return Sample(procRoot, now, defaultStatfs, overrides)
}

func parseProcFile[T any](procRoot, relPath string, parse func(r io.Reader) (T, error)) (T, error) {
	var zero T
	f, err := os.Open(filepath.Join(procRoot, relPath))
	if err != nil {
		return zero, err
	}
	defer f.Close()
	return parse(f)
}

// dedupeRealMounts filters mounts down to real, on-disk filesystems and
// keeps only the first (shortest-path) mount point per backing device —
// bind mounts of the same device would otherwise report identical usage
// under two different paths.
func dedupeRealMounts(mounts []proc.Mount) []proc.Mount {
	seenDevice := map[string]bool{}
	var out []proc.Mount
	sorted := append([]proc.Mount(nil), mounts...)
	sort.Slice(sorted, func(i, j int) bool { return len(sorted[i].MountPoint) < len(sorted[j].MountPoint) })
	for _, m := range sorted {
		if !realFilesystems[m.FSType] || seenDevice[m.Device] {
			continue
		}
		seenDevice[m.Device] = true
		out = append(out, m)
	}
	return out
}

// checkStatusMetricName maps a check's name to the metric name its numeric
// state is recorded under (check_<slug>_state, value 0/1/2/3 per
// checks.StatusFromExitCode) — queryable/graphable exactly like any other
// metric, for operators who want a state history chart.
func CheckStatusMetricName(checkName string) string {
	return fmt.Sprintf("check_%s_state", slug(checkName))
}

func slug(s string) string {
	out := make([]rune, 0, len(s))
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			out = append(out, r)
		case r >= 'A' && r <= 'Z':
			out = append(out, r-'A'+'a')
		default:
			out = append(out, '_')
		}
	}
	return string(out)
}

// StatusValue maps a checks.Status to the numeric state stored alongside
// it (0/1/2/3 = OK/WARNING/CRITICAL/UNKNOWN, the Nagios Plugin API's own
// convention already used elsewhere in this project).
func StatusValue(s checks.Status) float64 {
	switch s {
	case checks.StatusOK:
		return 0
	case checks.StatusWarning:
		return 1
	case checks.StatusCritical:
		return 2
	default:
		return 3
	}
}
