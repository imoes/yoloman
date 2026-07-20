package collect

import (
	"os"
	"testing"
	"time"
)

func TestDockerCPUPercent(t *testing.T) {
	var s dockerStats
	// container used 2 core-seconds while the system advanced 4; 4 online CPUs
	// → (2/4)*4*100 = 200% (two cores' worth).
	s.CPUStats.CPUUsage.TotalUsage = 3_000_000_000
	s.PreCPUStats.CPUUsage.TotalUsage = 1_000_000_000
	s.CPUStats.SystemUsage = 8_000_000_000
	s.PreCPUStats.SystemUsage = 4_000_000_000
	s.CPUStats.OnlineCPUs = 4
	if got := dockerCPUPercent(s); got != 200 {
		t.Errorf("cpu%% = %v, want 200", got)
	}

	// No system delta → 0 (avoids div-by-zero on the very first sample).
	var z dockerStats
	if got := dockerCPUPercent(z); got != 0 {
		t.Errorf("cpu%% (zero) = %v, want 0", got)
	}
}

func TestDockerMemUsage_SubtractsCache(t *testing.T) {
	var s dockerStats
	s.MemoryStats.Usage = 500
	s.MemoryStats.Stats = map[string]uint64{"inactive_file": 200}
	if got := dockerMemUsage(s); got != 300 {
		t.Errorf("mem = %v, want 300 (usage - inactive_file)", got)
	}
	// Falls back to cache (cgroup v1) when inactive_file is absent.
	s.MemoryStats.Stats = map[string]uint64{"cache": 100}
	if got := dockerMemUsage(s); got != 400 {
		t.Errorf("mem = %v, want 400 (usage - cache)", got)
	}
	// No cache stat → raw usage.
	s.MemoryStats.Stats = nil
	if got := dockerMemUsage(s); got != 500 {
		t.Errorf("mem = %v, want 500 (raw usage)", got)
	}
}

func TestContainerStatPoints(t *testing.T) {
	var s dockerStats
	s.CPUStats.CPUUsage.TotalUsage = 2_000_000_000
	s.PreCPUStats.CPUUsage.TotalUsage = 1_000_000_000
	s.CPUStats.SystemUsage = 4_000_000_000
	s.PreCPUStats.SystemUsage = 2_000_000_000
	s.CPUStats.OnlineCPUs = 1
	s.MemoryStats.Usage = 1024
	s.MemoryStats.Limit = 4096

	pts := containerStatPoints("nginx", s, time.Unix(0, 0))
	by := map[string]float64{}
	for _, p := range pts {
		if p.Labels["container"] != "nginx" {
			t.Errorf("point %s missing container label: %v", p.Metric, p.Labels)
		}
		by[p.Metric] = p.Value
	}
	if by["docker_container_cpu_pct"] != 50 { // (1/2)*1*100
		t.Errorf("cpu_pct = %v, want 50", by["docker_container_cpu_pct"])
	}
	if by["docker_container_mem_bytes"] != 1024 {
		t.Errorf("mem_bytes = %v, want 1024", by["docker_container_mem_bytes"])
	}
	if by["docker_container_mem_pct"] != 25 {
		t.Errorf("mem_pct = %v, want 25", by["docker_container_mem_pct"])
	}
}

func TestContainerName_StripsSlash(t *testing.T) {
	if got := containerName(dockerContainer{Names: []string{"/web"}}); got != "web" {
		t.Errorf("name = %q, want web", got)
	}
}

func TestDockerSample_NoSocketIsNoOp(t *testing.T) {
	d := NewDockerCollector(t.TempDir()+"/nonexistent.sock", "")
	pts, err := d.Sample(time.Now())
	if err != nil || pts != nil {
		t.Errorf("absent socket should be a clean no-op, got pts=%v err=%v", pts, err)
	}
	_ = os.Stat // keep os import meaningful across refactors
}
