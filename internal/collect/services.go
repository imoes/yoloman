package collect

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/store"
)

// ServiceCollector samples per-systemd-service resource usage straight from the
// cgroup filesystem — the way Coroot's node agent does it. This is the
// "eBPF/cgroup for legacy hosts" counterpart to the Docker collector: on a host
// that runs plain systemd services (no containers), every unit under
// system.slice still has a cgroup with cpu/memory/io accounting, so each
// service gets CPU/memory/IO metrics labeled by unit — without the service
// having to expose anything itself.
//
// cgroup v2 (unified, modern hosts) is preferred; v1 CPU+memory is handled as a
// fallback. Missing/unreadable files are skipped, so it's safe to run
// everywhere (returns no points on a host with no system.slice).
type ServiceCollector struct {
	// CgroupRoot is the cgroup mount (default /sys/fs/cgroup).
	CgroupRoot string
}

// NewServiceCollector returns a collector over the given cgroup root (empty →
// /sys/fs/cgroup).
func NewServiceCollector(cgroupRoot string) *ServiceCollector {
	if cgroupRoot == "" {
		cgroupRoot = "/sys/fs/cgroup"
	}
	return &ServiceCollector{CgroupRoot: cgroupRoot}
}

// Sample returns per-service metric points at time now.
func (s *ServiceCollector) Sample(now time.Time) ([]store.Point, error) {
	if _, err := os.Stat(filepath.Join(s.CgroupRoot, "cgroup.controllers")); err == nil {
		return s.sampleV2(now), nil // unified hierarchy
	}
	return s.sampleV1(now), nil
}

// sampleV2 reads system.slice/<unit>.service/{cpu.stat,memory.current,io.stat}.
func (s *ServiceCollector) sampleV2(now time.Time) []store.Point {
	base := filepath.Join(s.CgroupRoot, "system.slice")
	entries, err := os.ReadDir(base)
	if err != nil {
		return nil
	}
	var points []store.Point
	for _, e := range entries {
		if !e.IsDir() || !strings.HasSuffix(e.Name(), ".service") {
			continue
		}
		unit := strings.TrimSuffix(e.Name(), ".service")
		dir := filepath.Join(base, e.Name())
		labels := map[string]string{"unit": unit}
		running := false

		if usec, ok := readKVUint(filepath.Join(dir, "cpu.stat"), "usage_usec"); ok {
			points = append(points, store.Point{Metric: "service_cpu_seconds_total", Timestamp: now, Value: float64(usec) / 1e6, Labels: labels})
			running = true
		}
		if mem, ok := readUint(filepath.Join(dir, "memory.current")); ok {
			points = append(points, store.Point{Metric: "service_memory_bytes", Timestamp: now, Value: float64(mem), Labels: labels})
			running = true
		}
		if r, w, ok := readIOStat(filepath.Join(dir, "io.stat")); ok {
			points = append(points,
				store.Point{Metric: "service_io_read_bytes_total", Timestamp: now, Value: float64(r), Labels: labels},
				store.Point{Metric: "service_io_write_bytes_total", Timestamp: now, Value: float64(w), Labels: labels},
			)
		}
		if running {
			points = append(points, store.Point{Metric: "service_running", Timestamp: now, Value: 1, Labels: labels})
		}
	}
	return points
}

// sampleV1 reads the split v1 hierarchy for CPU + memory per unit.
func (s *ServiceCollector) sampleV1(now time.Time) []store.Point {
	var points []store.Point
	cpuBase := filepath.Join(s.CgroupRoot, "cpu,cpuacct", "system.slice")
	if entries, err := os.ReadDir(cpuBase); err == nil {
		for _, e := range entries {
			if !e.IsDir() || !strings.HasSuffix(e.Name(), ".service") {
				continue
			}
			unit := strings.TrimSuffix(e.Name(), ".service")
			if ns, ok := readUint(filepath.Join(cpuBase, e.Name(), "cpuacct.usage")); ok {
				points = append(points, store.Point{Metric: "service_cpu_seconds_total", Timestamp: now, Value: float64(ns) / 1e9, Labels: map[string]string{"unit": unit}})
				points = append(points, store.Point{Metric: "service_running", Timestamp: now, Value: 1, Labels: map[string]string{"unit": unit}})
			}
		}
	}
	memBase := filepath.Join(s.CgroupRoot, "memory", "system.slice")
	if entries, err := os.ReadDir(memBase); err == nil {
		for _, e := range entries {
			if !e.IsDir() || !strings.HasSuffix(e.Name(), ".service") {
				continue
			}
			unit := strings.TrimSuffix(e.Name(), ".service")
			if mem, ok := readUint(filepath.Join(memBase, e.Name(), "memory.usage_in_bytes")); ok {
				points = append(points, store.Point{Metric: "service_memory_bytes", Timestamp: now, Value: float64(mem), Labels: map[string]string{"unit": unit}})
			}
		}
	}
	return points
}

// readUint reads a file containing a single unsigned integer ("max" → not ok).
func readUint(path string) (uint64, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	v, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

// readKVUint reads a "key value" line file (cpu.stat, memory.stat) and returns
// the uint value for key.
func readKVUint(path, key string) (uint64, bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 2 && fields[0] == key {
			if v, err := strconv.ParseUint(fields[1], 10, 64); err == nil {
				return v, true
			}
		}
	}
	return 0, false
}

// readIOStat sums rbytes/wbytes across all devices in a v2 io.stat file.
func readIOStat(path string) (read, write uint64, ok bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		for _, tok := range strings.Fields(sc.Text()) {
			k, v, found := strings.Cut(tok, "=")
			if !found {
				continue
			}
			n, err := strconv.ParseUint(v, 10, 64)
			if err != nil {
				continue
			}
			switch k {
			case "rbytes":
				read += n
				ok = true
			case "wbytes":
				write += n
				ok = true
			}
		}
	}
	return read, write, ok
}
