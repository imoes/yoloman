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

func TestResourcesToHosts(t *testing.T) {
	rs := []proxmoxResource{
		{Type: "qemu", Name: "web01", Status: "running", CPU: 0.25, MaxCPU: 4, Mem: 2 << 30, MaxMem: 8 << 30, Uptime: 3600},
		{Type: "lxc", Name: "db-ct", Status: "stopped", CPU: 0, MaxCPU: 2, Mem: 0, MaxMem: 4 << 30},
		{Type: "node", Name: "pve1"}, // ignored
		{Type: "storage", Name: "local"}, // ignored
	}
	hosts := resourcesToHosts(rs)
	if len(hosts) != 2 {
		t.Fatalf("got %d hosts, want 2 (qemu+lxc only)", len(hosts))
	}
	m := metricMap(hosts[0].Metrics)
	if hosts[0].Name != "web01" || m["vm_cpu_pct"] != 25 || m["vm_running"] != 1 {
		t.Errorf("web01 wrong: name=%s cpu=%v running=%v", hosts[0].Name, m["vm_cpu_pct"], m["vm_running"])
	}
	if m["vm_mem_pct"] != 25 {
		t.Errorf("web01 mem_pct = %v, want 25", m["vm_mem_pct"])
	}
	if metricMap(hosts[1].Metrics)["vm_running"] != 0 {
		t.Errorf("db-ct should be not running")
	}
}

func TestVmsToHosts(t *testing.T) {
	vms := []vsphereVM{
		{VM: "vm-1", Name: "app01", PowerState: "POWERED_ON", CPUCount: 4, MemMiB: 8192},
		{VM: "vm-2", Name: "", PowerState: "POWERED_OFF"},
	}
	hosts := vmsToHosts(vms)
	if len(hosts) != 2 || hosts[0].Name != "app01" || hosts[1].Name != "vm-2" {
		t.Fatalf("names wrong: %+v", hosts)
	}
	m := metricMap(hosts[0].Metrics)
	if m["vm_running"] != 1 || m["vm_cpu_count"] != 4 || m["vm_mem_bytes"] != 8192*1024*1024 {
		t.Errorf("app01 metrics wrong: %+v", m)
	}
	if metricMap(hosts[1].Metrics)["vm_running"] != 0 {
		t.Errorf("vm-2 should be off")
	}
}

func metricMap(ms []Metric) map[string]float64 {
	m := map[string]float64{}
	for _, x := range ms {
		m[x.Name] = x.Value
	}
	return m
}
