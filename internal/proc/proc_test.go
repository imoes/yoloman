package proc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func openFixture(t *testing.T, name string) *os.File {
	t.Helper()
	f, err := os.Open(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("opening fixture %q: %v", name, err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

func TestParseMemInfo(t *testing.T) {
	info, err := ParseMemInfo(openFixture(t, "meminfo"))
	if err != nil {
		t.Fatalf("ParseMemInfo: %v", err)
	}
	if info["MemTotal"] != 32857976 {
		t.Errorf("MemTotal = %d, want 32857976", info["MemTotal"])
	}
	if info["MemFree"] != 4311652 {
		t.Errorf("MemFree = %d, want 4311652", info["MemFree"])
	}
	if _, ok := info["SwapTotal"]; !ok {
		t.Errorf("expected SwapTotal key to be present")
	}
}

func TestParseLoadAvg(t *testing.T) {
	la, err := ParseLoadAvg(openFixture(t, "loadavg"))
	if err != nil {
		t.Fatalf("ParseLoadAvg: %v", err)
	}
	if la.Load1 != 0.07 || la.Load5 != 0.26 || la.Load15 != 0.25 {
		t.Errorf("unexpected load averages: %+v", la)
	}
	if la.RunnableProcs != 1 || la.TotalProcs != 2288 {
		t.Errorf("unexpected running/total procs: %+v", la)
	}
	if la.LastPID != 1621962 {
		t.Errorf("LastPID = %d, want 1621962", la.LastPID)
	}
}

func TestParseLoadAvg_Malformed(t *testing.T) {
	_, err := ParseLoadAvg(strings.NewReader("not enough fields"))
	if err == nil {
		t.Fatal("expected error for malformed loadavg")
	}
}

func TestParseUptime(t *testing.T) {
	u, err := ParseUptime(openFixture(t, "uptime"))
	if err != nil {
		t.Fatalf("ParseUptime: %v", err)
	}
	if u.UptimeSeconds != 98054.94 {
		t.Errorf("UptimeSeconds = %v, want 98054.94", u.UptimeSeconds)
	}
	if u.IdleSeconds != 760410.48 {
		t.Errorf("IdleSeconds = %v, want 760410.48", u.IdleSeconds)
	}
}

func TestParseCPUInfo(t *testing.T) {
	cpus, err := ParseCPUInfo(openFixture(t, "cpuinfo"))
	if err != nil {
		t.Fatalf("ParseCPUInfo: %v", err)
	}
	if len(cpus) == 0 {
		t.Fatal("expected at least one CPU block")
	}
	first := cpus[0]
	if first["vendor_id"] != "AuthenticAMD" {
		t.Errorf("vendor_id = %q, want AuthenticAMD", first["vendor_id"])
	}
	if first["model name"] == "" {
		t.Errorf("expected non-empty model name")
	}
}

func TestParseMounts(t *testing.T) {
	mounts, err := ParseMounts(openFixture(t, "mounts"))
	if err != nil {
		t.Fatalf("ParseMounts: %v", err)
	}
	if len(mounts) == 0 {
		t.Fatal("expected at least one mount")
	}
	var found bool
	for _, m := range mounts {
		if m.MountPoint == "/proc" {
			found = true
			if m.FSType != "proc" {
				t.Errorf("fs type for /proc = %q, want proc", m.FSType)
			}
			if len(m.Options) == 0 {
				t.Errorf("expected mount options to be parsed")
			}
		}
	}
	if !found {
		t.Error("expected to find /proc mount entry")
	}
}

func TestParseNetDev(t *testing.T) {
	stats, err := ParseNetDev(openFixture(t, "net_dev"))
	if err != nil {
		t.Fatalf("ParseNetDev: %v", err)
	}
	var lo *NetDevStats
	for i := range stats {
		if stats[i].Interface == "lo" {
			lo = &stats[i]
		}
	}
	if lo == nil {
		t.Fatal("expected lo interface in net/dev stats")
	}
	if lo.RxBytes != 906384047 {
		t.Errorf("lo RxBytes = %d, want 906384047", lo.RxBytes)
	}
	if lo.TxBytes != 906384047 {
		t.Errorf("lo TxBytes = %d, want 906384047", lo.TxBytes)
	}
}

func TestParseDiskStats(t *testing.T) {
	stats, err := ParseDiskStats(openFixture(t, "diskstats"))
	if err != nil {
		t.Fatalf("ParseDiskStats: %v", err)
	}
	if len(stats) == 0 {
		t.Fatal("expected at least one disk entry")
	}
	first := stats[0]
	if first.Device != "loop0" {
		t.Errorf("first device = %q, want loop0", first.Device)
	}
	if first.ReadsCompleted != 14 {
		t.Errorf("ReadsCompleted = %d, want 14", first.ReadsCompleted)
	}
}
