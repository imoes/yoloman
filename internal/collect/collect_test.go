package collect

import (
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/checks"
	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/store"
)

func fakeStatfs(usedPct float64, total, used uint64) statfsFunc {
	return func(mountPoint string) (float64, uint64, uint64, error) {
		return usedPct, total, used, nil
	}
}

func metricValue(t *testing.T, snap Snapshot, metric string, labels map[string]string) float64 {
	t.Helper()
	for _, p := range snap.Points {
		if p.Metric != metric {
			continue
		}
		if labels == nil && len(p.Labels) == 0 {
			return p.Value
		}
		if labels != nil {
			match := true
			for k, v := range labels {
				if p.Labels[k] != v {
					match = false
					break
				}
			}
			if match {
				return p.Value
			}
		}
	}
	t.Fatalf("metric %q (labels %v) not found in snapshot points %+v", metric, labels, snap.Points)
	return 0
}

func TestSample_WritesCanonicalMetrics(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	snap, err := Sample("testdata", now, fakeStatfs(42.5, 1000, 425), nil)
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}

	if got := metricValue(t, snap, "cpu_load1", nil); got != 0.50 {
		t.Errorf("cpu_load1 = %v, want 0.50", got)
	}
	if got := metricValue(t, snap, "cpu_load5", nil); got != 0.75 {
		t.Errorf("cpu_load5 = %v, want 0.75", got)
	}
	if got := metricValue(t, snap, "cpu_count", nil); got != 2 {
		t.Errorf("cpu_count = %v, want 2", got)
	}
	if got := metricValue(t, snap, "mem_used_pct", nil); got != 50 {
		t.Errorf("mem_used_pct = %v, want 50 (16000000-8000000)/16000000*100", got)
	}
	if got := metricValue(t, snap, "uptime_seconds", nil); got != 3600.50 {
		t.Errorf("uptime_seconds = %v, want 3600.50", got)
	}
	if got := metricValue(t, snap, "net_rx_bytes", map[string]string{"iface": "eth0"}); got != 50000 {
		t.Errorf("net_rx_bytes{iface=eth0} = %v, want 50000", got)
	}
	for _, p := range snap.Points {
		if p.Metric == "net_rx_bytes" && p.Labels["iface"] == "lo" {
			t.Errorf("loopback interface should be excluded, found %+v", p)
		}
	}
}

func TestSample_OnlyRealDedupedMountsGetDiskMetrics(t *testing.T) {
	now := time.Now()
	snap, err := Sample("testdata", now, fakeStatfs(42.5, 1000, 425), nil)
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}

	seenMounts := map[string]bool{}
	for _, p := range snap.Points {
		if p.Metric == "disk_used_pct" {
			seenMounts[p.Labels["mount"]] = true
		}
	}
	if !seenMounts["/"] {
		t.Errorf("expected / (ext4) to be sampled, got mounts %v", seenMounts)
	}
	if seenMounts["/var/lib/bindmount"] {
		t.Errorf("bind mount of the same device as / should be deduped, got mounts %v", seenMounts)
	}
	if seenMounts["/var/lib/docker/overlay2/abc/merged"] {
		t.Errorf("overlay (virtual) filesystem should be excluded, got mounts %v", seenMounts)
	}
	if seenMounts["/proc"] || seenMounts["/sys"] || seenMounts["/run"] {
		t.Errorf("pseudo filesystems (proc/sysfs/tmpfs) should be excluded, got mounts %v", seenMounts)
	}
	if got := metricValue(t, snap, "disk_used_pct", map[string]string{"mount": "/"}); got != 42.5 {
		t.Errorf("disk_used_pct{mount=/} = %v, want 42.5", got)
	}
}

func TestSample_BuiltinChecksReflectThresholds(t *testing.T) {
	now := time.Now()
	// mem_used_pct will be 50% (OK); disk at 95% (CRIT, from fakeStatfs).
	snap, err := Sample("testdata", now, fakeStatfs(95.0, 1000, 950), nil)
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}

	byName := map[string]CheckResult{}
	for _, c := range snap.Checks {
		byName[c.Name] = c
	}

	mem, ok := byName["Memory"]
	if !ok {
		t.Fatalf("expected a Memory check, got %+v", snap.Checks)
	}
	if mem.Status != checks.StatusOK {
		t.Errorf("Memory status = %v, want OK (50%% used)", mem.Status)
	}

	disk, ok := byName["Disk /"]
	if !ok {
		t.Fatalf("expected a 'Disk /' check, got %+v", snap.Checks)
	}
	if disk.Status != checks.StatusCritical {
		t.Errorf("Disk / status = %v, want CRITICAL (95%% used)", disk.Status)
	}

	if _, ok := byName["Uptime"]; !ok {
		t.Errorf("expected an Uptime check, got %+v", snap.Checks)
	}
	if _, ok := byName["CPU load"]; !ok {
		t.Errorf("expected a CPU load check, got %+v", snap.Checks)
	}
}

func TestSample_ThresholdOverrideFlipsMemoryToCritical(t *testing.T) {
	now := time.Now()
	// mem_used_pct is 50%. Default warn/crit are 80/90 → OK. A pushed
	// override of warn=40/crit=45 must flip the Memory check to CRITICAL,
	// proving the pushed desired state changes real check behavior.
	warn, crit := 40.0, 45.0
	overrides := map[string]ThresholdOverride{"mem_used_pct": {Warn: &warn, Crit: &crit}}
	snap, err := Sample("testdata", now, fakeStatfs(42.5, 1000, 425), overrides)
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}
	byName := map[string]CheckResult{}
	for _, c := range snap.Checks {
		byName[c.Name] = c
	}
	if byName["Memory"].Status != checks.StatusCritical {
		t.Errorf("Memory status = %v, want CRITICAL under override warn=40/crit=45 at 50%% used", byName["Memory"].Status)
	}
}

func TestSample_CPULoadOverrideUsesAbsoluteLoad(t *testing.T) {
	now := time.Now()
	// testdata load5 = 0.75 on 2 cores → per-core 0.375, OK by default.
	// An absolute cpu_load5 override of warn=0.5/crit=0.7 must flip CPU load
	// to CRITICAL (0.75 >= 0.7 absolute), confirming the override switches to
	// the absolute-load basis.
	warn, crit := 0.5, 0.7
	overrides := map[string]ThresholdOverride{"cpu_load5": {Warn: &warn, Crit: &crit}}
	snap, err := Sample("testdata", now, fakeStatfs(42.5, 1000, 425), overrides)
	if err != nil {
		t.Fatalf("Sample: %v", err)
	}
	byName := map[string]CheckResult{}
	for _, c := range snap.Checks {
		byName[c.Name] = c
	}
	if byName["CPU load"].Status != checks.StatusCritical {
		t.Errorf("CPU load status = %v, want CRITICAL under absolute override crit=0.7 at load5=0.75", byName["CPU load"].Status)
	}
}

func TestSample_MissingProcFilesDegradeGracefully(t *testing.T) {
	now := time.Now()
	snap, err := Sample("testdata/does-not-exist", now, fakeStatfs(1, 1, 1), nil)
	if err != nil {
		t.Fatalf("Sample should degrade gracefully, not error, on a missing procRoot: %v", err)
	}
	if len(snap.Points) != 0 {
		t.Errorf("expected no points when nothing under procRoot exists, got %+v", snap.Points)
	}
	if len(snap.Checks) != 0 {
		t.Errorf("expected no checks when no metrics were sampled, got %+v", snap.Checks)
	}
}

func TestCheckRegistry_SetAndSnapshot(t *testing.T) {
	reg := NewCheckRegistry()
	now := time.Now()
	reg.Set("b-check", checks.Result{Status: checks.StatusWarning, Message: "b"}, now)
	reg.Set("a-check", checks.Result{Status: checks.StatusOK, Message: "a"}, now)
	reg.Set("b-check", checks.Result{Status: checks.StatusCritical, Message: "b2"}, now) // overwrite

	snap := reg.Snapshot()
	if len(snap) != 2 {
		t.Fatalf("expected 2 distinct checks, got %d: %+v", len(snap), snap)
	}
	if snap[0].Name != "a-check" || snap[1].Name != "b-check" {
		t.Errorf("expected sorted by name, got %+v", snap)
	}
	if snap[1].Status != checks.StatusCritical || snap[1].Message != "b2" {
		t.Errorf("expected the overwritten result, got %+v", snap[1])
	}
}

func TestStatusValue(t *testing.T) {
	cases := map[checks.Status]float64{
		checks.StatusOK: 0, checks.StatusWarning: 1, checks.StatusCritical: 2, checks.StatusUnknown: 3,
	}
	for status, want := range cases {
		if got := StatusValue(status); got != want {
			t.Errorf("StatusValue(%v) = %v, want %v", status, got, want)
		}
	}
}

func TestCheckStatusMetricName(t *testing.T) {
	if got := CheckStatusMetricName("Disk /"); got != "check_disk___state" {
		t.Errorf("CheckStatusMetricName(%q) = %q, want %q", "Disk /", got, "check_disk___state")
	}
	if got := CheckStatusMetricName("CPU load"); got != "check_cpu_load_state" {
		t.Errorf("CheckStatusMetricName(%q) = %q, want %q", "CPU load", got, "check_cpu_load_state")
	}
}

func TestExcludeDRBDDevicesDropsOnlyTheDRBDLayer(t *testing.T) {
	points := []store.Point{
		{Metric: "disk_iops_device", Labels: map[string]string{"device": "drbd1000", "vm": "221100"}},
		{Metric: "disk_writes_total", Labels: map[string]string{"device": "drbd1008", "vm": "221101"}},
		{Metric: "disk_iops_device", Labels: map[string]string{"device": "zd16", "vm": "221106"}},
		{Metric: "disk_iops_device", Labels: map[string]string{"device": "nvme0n1"}},
		{Metric: "disk_iops", Value: 32.8}, // the server total, label-less
		{Metric: "cpu_pct", Value: 4.0},
		// "drbdmanage" is not a device name of the form drbd<N> and must survive.
		{Metric: "disk_iops_device", Labels: map[string]string{"device": "drbdmanage"}},
	}
	got := ExcludeDRBDDevices(points)

	var devices []string
	for _, p := range got {
		if d := p.Labels["device"]; d != "" {
			devices = append(devices, d)
		}
	}
	want := []string{"zd16", "nvme0n1", "drbdmanage"}
	if len(devices) != len(want) {
		t.Fatalf("devices = %v, want %v", devices, want)
	}
	for i, d := range devices {
		if d != want[i] {
			t.Errorf("devices[%d] = %q, want %q", i, d, want[i])
		}
	}
	// The zvol keeps its vm label: on vpp0222/0223 that is what makes dropping DRBD lossless.
	for _, p := range got {
		if p.Labels["device"] == "zd16" && p.Labels["vm"] != "221106" {
			t.Error("the zvol lost its vm label — then switching DRBD off WOULD lose attribution")
		}
	}
	// The server total and unrelated metrics are untouched.
	var kept int
	for _, p := range got {
		if p.Metric == "disk_iops" || p.Metric == "cpu_pct" {
			kept++
		}
	}
	if kept != 2 {
		t.Errorf("kept %d label-less/unrelated points, want 2", kept)
	}
}

func TestDRBDDevicesDefaultsToOnSoNoHostSilentlyLosesItsOnlyGuestView(t *testing.T) {
	// vpp0221 has nine DRBD devices and zero zvols; an off-by-default flag would blind it.
	if !config.Default().Collect.DRBDDevices {
		t.Error("collect.drbd_devices must default to true")
	}
}

func TestExcludeMetricsDropsByExactNameOnly(t *testing.T) {
	points := []store.Point{
		{Metric: "disk_reads_total", Labels: map[string]string{"device": "sda"}},
		{Metric: "disk_writes_total", Labels: map[string]string{"device": "sda"}},
		{Metric: "disk_read_time_ms_total", Labels: map[string]string{"device": "sda"}},
		// Kept: the byte counters still feed "Bytes read/written per device".
		{Metric: "disk_read_bytes_total", Labels: map[string]string{"device": "sda"}},
		// Kept: the derived rate is what the IOPS view and the Disk IOPS check use.
		{Metric: "disk_iops_device", Labels: map[string]string{"device": "sda"}},
		// Kept: a prefix-based filter would have taken this one, and the guest view reads it.
		{Metric: "container_cpu_pct"},
		{Metric: "container_net_rx_bytes"},
		{Metric: "disk_used_pct", Labels: map[string]string{"mount": "/"}},
	}
	got := ExcludeMetrics(points, []string{
		"disk_reads_total", "disk_writes_total", "disk_read_time_ms_total", "container_net_rx_bytes",
	})

	var names []string
	for _, p := range got {
		names = append(names, p.Metric)
	}
	want := []string{"disk_read_bytes_total", "disk_iops_device", "container_cpu_pct", "disk_used_pct"}
	if len(names) != len(want) {
		t.Fatalf("kept %v, want %v", names, want)
	}
	for i, n := range names {
		if n != want[i] {
			t.Errorf("kept[%d] = %q, want %q", i, n, want[i])
		}
	}
}

func TestExcludeMetricsWithNoNamesIsAPassThrough(t *testing.T) {
	points := []store.Point{{Metric: "cpu_pct"}, {Metric: "mem_used_pct"}}
	for _, names := range [][]string{nil, {}} {
		if got := ExcludeMetrics(points, names); len(got) != 2 {
			t.Errorf("names=%v dropped points: %d of 2 left", names, len(got))
		}
	}
}

func TestDropMetricsDefaultsToEmptySoNothingVanishesUnasked(t *testing.T) {
	if len(config.Default().Collect.DropMetrics) != 0 {
		t.Error("collect.drop_metrics must default to empty — dropping a metric is always explicit")
	}
}
