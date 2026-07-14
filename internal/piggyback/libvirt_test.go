package piggyback

import "testing"

// sample `virsh domstats --state --cpu-total --balloon --vcpu` output for one
// running domain; the second domain (db01) is defined but shut off, so it never
// appears in domstats.
const domstatsSample = `Domain: 'web01'
  state.state=1
  state.reason=1
  cpu.time=42000000000
  cpu.user=1000000000
  balloon.current=2097152
  balloon.maximum=4194304
  vcpu.current=2
  vcpu.maximum=4

`

func TestParseDomstats(t *testing.T) {
	s := parseDomstats(domstatsSample)
	web, ok := s["web01"]
	if !ok {
		t.Fatalf("web01 not parsed: %v", s)
	}
	if web["state.state"] != "1" || web["balloon.current"] != "2097152" || web["vcpu.current"] != "2" {
		t.Fatalf("bad parse: %v", web)
	}
}

func TestDomainsToHosts(t *testing.T) {
	stats := parseDomstats(domstatsSample)
	hosts := domainsToHosts([]string{"web01", "db01"}, stats)
	if len(hosts) != 2 {
		t.Fatalf("want 2 hosts, got %d", len(hosts))
	}
	m := map[string]map[string]float64{}
	for _, h := range hosts {
		mm := map[string]float64{}
		for _, x := range h.Metrics {
			mm[x.Name] = x.Value
		}
		m[h.Name] = mm
	}
	// running domain: full metric set, byte conversion + pct.
	web := m["web01"]
	if web["vm_running"] != 1 {
		t.Fatalf("web01 vm_running = %v", web["vm_running"])
	}
	if web["vm_vcpus"] != 2 {
		t.Fatalf("web01 vm_vcpus = %v", web["vm_vcpus"])
	}
	if web["vm_mem_used_bytes"] != 2097152*1024 {
		t.Fatalf("web01 vm_mem_used_bytes = %v", web["vm_mem_used_bytes"])
	}
	if web["vm_mem_pct"] != 50 { // 2097152 / 4194304 * 100
		t.Fatalf("web01 vm_mem_pct = %v", web["vm_mem_pct"])
	}
	if web["vm_cpu_time_seconds"] != 42 { // 42e9 ns
		t.Fatalf("web01 vm_cpu_time_seconds = %v", web["vm_cpu_time_seconds"])
	}
	// inactive domain: only vm_running=0, no memory/cpu noise.
	db := m["db01"]
	if db["vm_running"] != 0 {
		t.Fatalf("db01 vm_running = %v", db["vm_running"])
	}
	if _, has := db["vm_mem_used_bytes"]; has {
		t.Fatalf("db01 should have no memory metric: %v", db)
	}
}
