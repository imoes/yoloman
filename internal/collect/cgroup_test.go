package collect

import (
	"testing"
	"time"
)

func TestReadPSI(t *testing.T) {
	some, full, ok := readPSI("testdata/cgroup2/system.slice/nginx.service/cpu.pressure")
	if !ok {
		t.Fatal("readPSI: ok=false, want true")
	}
	if some == nil || some.Avg10 != 1.50 || some.Avg60 != 2.25 || some.Avg300 != 3.75 || some.TotalUsec != 1234567 {
		t.Errorf("some = %+v, want {1.50 2.25 3.75 1234567}", some)
	}
	if full == nil || full.Avg10 != 0.50 || full.TotalUsec != 234567 {
		t.Errorf("full = %+v, want avg10=0.50 total=234567", full)
	}
	if _, _, ok := readPSI("testdata/cgroup2/system.slice/ssh.service/cpu.pressure"); ok {
		t.Error("readPSI on missing file: ok=true, want false")
	}
}

func TestReadCPUThrottle(t *testing.T) {
	periods, throttled, usec, ok := readCPUThrottle("testdata/cgroup2/system.slice/nginx.service/cpu.stat")
	if !ok {
		t.Fatal("readCPUThrottle: ok=false, want true")
	}
	if periods != 100 || throttled != 7 || usec != 3000000 {
		t.Errorf("got periods=%d throttled=%d usec=%d, want 100/7/3000000", periods, throttled, usec)
	}
	// ssh.service's cpu.stat has only usage_usec — no throttle keys.
	if _, _, _, ok := readCPUThrottle("testdata/cgroup2/system.slice/ssh.service/cpu.stat"); ok {
		t.Error("readCPUThrottle without throttle keys: ok=true, want false")
	}
}

func TestPSIPoints(t *testing.T) {
	base := map[string]string{"unit": "nginx"}
	some := &PSILine{Avg10: 1.5, Avg60: 2.25, Avg300: 3.75, TotalUsec: 1234567}
	full := &PSILine{Avg10: 0.5, TotalUsec: 234567}
	pts := psiPoints("service_cpu_pressure", base, time.Now(), some, full)
	// 2 kinds × (3 window pct + 1 stalled_total) = 8 points.
	if len(pts) != 8 {
		t.Fatalf("got %d points, want 8", len(pts))
	}
	// The shared base map must never be mutated.
	if _, mutated := base["kind"]; mutated {
		t.Error("psiPoints mutated the caller's label map")
	}
	var stalled float64
	var pct10 float64
	for _, p := range pts {
		if p.Metric == "service_cpu_pressure_stalled_seconds_total" && p.Labels["kind"] == "some" {
			stalled = p.Value
		}
		if p.Metric == "service_cpu_pressure_pct" && p.Labels["kind"] == "some" && p.Labels["window"] == "10s" {
			pct10 = p.Value
		}
	}
	if stalled != 1.234567 {
		t.Errorf("some stalled_seconds = %v, want 1.234567", stalled)
	}
	if pct10 != 1.5 {
		t.Errorf("some pct[10s] = %v, want 1.5", pct10)
	}
}

func TestPSIPointsNilFull(t *testing.T) {
	// A PSI file with only a "some" line (full omitted) yields 4 points.
	pts := psiPoints("service_io_pressure", map[string]string{"unit": "x"}, time.Now(), &PSILine{Avg10: 0.1}, nil)
	if len(pts) != 4 {
		t.Fatalf("got %d points, want 4 (some only)", len(pts))
	}
}

func TestContainerCgroupPath(t *testing.T) {
	orig := readProcCgroup
	defer func() { readProcCgroup = orig }()
	readProcCgroup = func(string) ([]byte, error) {
		return []byte("0::/system.slice/docker-abc123.scope\n"), nil
	}
	path, ok := containerCgroupPath("/sys/fs/cgroup", 4242)
	if !ok || path != "/sys/fs/cgroup/system.slice/docker-abc123.scope" {
		t.Errorf("got %q (ok=%v), want /sys/fs/cgroup/system.slice/docker-abc123.scope", path, ok)
	}
	// pid<=0 → not running.
	if _, ok := containerCgroupPath("/sys/fs/cgroup", 0); ok {
		t.Error("pid=0: ok=true, want false")
	}
	// A v1 host (no "0::" line) → not resolvable.
	readProcCgroup = func(string) ([]byte, error) {
		return []byte("6:memory:/docker/abc123\n"), nil
	}
	if _, ok := containerCgroupPath("/sys/fs/cgroup", 4242); ok {
		t.Error("v1 host: ok=true, want false")
	}
}

func TestServiceCollector_PressureAndThrottle(t *testing.T) {
	c := NewServiceCollector("testdata/cgroup2")
	points, err := c.Sample(time.Now())
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}
	get := func(metric, unit, kind, window string) (float64, bool) {
		for _, p := range points {
			if p.Metric == metric && p.Labels["unit"] == unit &&
				(kind == "" || p.Labels["kind"] == kind) &&
				(window == "" || p.Labels["window"] == window) {
				return p.Value, true
			}
		}
		return 0, false
	}
	if v, ok := get("service_cpu_pressure_pct", "nginx", "some", "10s"); !ok || v != 1.5 {
		t.Errorf("nginx cpu pressure some[10s] = %v (ok=%v), want 1.5", v, ok)
	}
	if v, ok := get("service_cpu_throttled_seconds_total", "nginx", "", ""); !ok || v != 3.0 {
		t.Errorf("nginx cpu throttled seconds = %v (ok=%v), want 3.0", v, ok)
	}
	if v, ok := get("service_cpu_periods_total", "nginx", "", ""); !ok || v != 100 {
		t.Errorf("nginx cpu periods = %v (ok=%v), want 100", v, ok)
	}
	// ssh.service has no pressure/throttle fixtures → those metrics absent, no panic.
	if _, ok := get("service_cpu_pressure_pct", "ssh", "", ""); ok {
		t.Error("ssh should have no cpu pressure metric")
	}
}
