package piggyback

import "testing"

func TestStatsToMetrics(t *testing.T) {
	var st dockerStats
	// 20% of 2 CPUs: cpuDelta/sysDelta = 0.4 over 2 CPUs → 40%.
	st.CPUStats.CPUUsage.TotalUsage = 400
	st.PreCPUStats.CPUUsage.TotalUsage = 0
	st.CPUStats.SystemUsage = 1000
	st.PreCPUStats.SystemUsage = 0
	st.CPUStats.OnlineCPUs = 2
	st.MemoryStats.Usage = 200 * 1024 * 1024
	st.MemoryStats.Limit = 1024 * 1024 * 1024
	st.MemoryStats.Stats = map[string]uint64{"inactive_file": 50 * 1024 * 1024}
	st.Networks = map[string]struct {
		RxBytes uint64 `json:"rx_bytes"`
		TxBytes uint64 `json:"tx_bytes"`
	}{"eth0": {RxBytes: 1000, TxBytes: 500}}

	m := map[string]float64{}
	for _, x := range statsToMetrics(st) {
		m[x.Name] = x.Value
	}
	if got := m["container_cpu_pct"]; got < 79.9 || got > 80.1 {
		t.Errorf("cpu_pct = %v, want ~80", got)
	}
	if got := m["container_mem_used_bytes"]; got != float64(150*1024*1024) {
		t.Errorf("mem_used = %v, want 150MiB (usage - inactive_file)", got)
	}
	if got := m["container_mem_pct"]; got < 14.5 || got > 14.7 {
		t.Errorf("mem_pct = %v, want ~14.6", got)
	}
	if m["container_net_rx_bytes"] != 1000 || m["container_net_tx_bytes"] != 500 {
		t.Errorf("net rx/tx wrong: %v/%v", m["container_net_rx_bytes"], m["container_net_tx_bytes"])
	}
}

func TestContainerName(t *testing.T) {
	if containerName([]string{"/upbeat_borg"}) != "upbeat_borg" {
		t.Error("leading slash not stripped")
	}
	if containerName(nil) != "" {
		t.Error("empty names should yield empty")
	}
}
