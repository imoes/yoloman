package collect

import (
	"testing"
	"time"
)

func TestServiceCollector_CgroupV2(t *testing.T) {
	c := NewServiceCollector("testdata/cgroup2")
	points, err := c.Sample(time.Now())
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}
	// Index by metric+unit.
	get := func(metric, unit string) (float64, bool) {
		for _, p := range points {
			if p.Metric == metric && p.Labels["unit"] == unit {
				return p.Value, true
			}
		}
		return 0, false
	}

	if v, ok := get("service_cpu_seconds_total", "nginx"); !ok || v != 5.0 {
		t.Errorf("nginx cpu = %v (ok=%v), want 5.0 (5000000 usec)", v, ok)
	}
	if v, ok := get("service_memory_bytes", "nginx"); !ok || v != 104857600 {
		t.Errorf("nginx mem = %v (ok=%v), want 104857600", v, ok)
	}
	if v, ok := get("service_io_read_bytes_total", "nginx"); !ok || v != 1000 {
		t.Errorf("nginx io read = %v (ok=%v), want 1000", v, ok)
	}
	if v, ok := get("service_io_write_bytes_total", "nginx"); !ok || v != 2000 {
		t.Errorf("nginx io write = %v (ok=%v), want 2000", v, ok)
	}
	if v, ok := get("service_running", "nginx"); !ok || v != 1 {
		t.Errorf("nginx running = %v (ok=%v), want 1", v, ok)
	}
	if v, ok := get("service_cpu_seconds_total", "ssh"); !ok || v != 1.0 {
		t.Errorf("ssh cpu = %v (ok=%v), want 1.0", v, ok)
	}
}

func TestServiceCollector_NoCgroup(t *testing.T) {
	// A host without the tree returns no points and no error.
	c := NewServiceCollector("testdata/does-not-exist")
	points, err := c.Sample(time.Now())
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}
	if len(points) != 0 {
		t.Errorf("expected no points, got %d", len(points))
	}
}
