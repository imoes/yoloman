package collect

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// diskstats line layout: major minor device reads rmerged sread ms_read
// writes wmerged swritten ms_write ...
func writeDiskstats(t *testing.T, dir string, reads, writes uint64) {
	t.Helper()
	line := "   8       0 sda " +
		itoa(reads) + " 0 100 50 " + itoa(writes) + " 0 200 60 0 0 0\n" +
		"   7       0 loop0 999 0 0 0 999 0 0 0 0 0 0\n" // loopback must be ignored
	if err := os.WriteFile(filepath.Join(dir, "diskstats"), []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
}

func itoa(v uint64) string { return strconvFormat(v) }

func strconvFormat(v uint64) string {
	if v == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	return string(b[i:])
}

func TestDiskIOMeter_FirstSamplePrimes(t *testing.T) {
	dir := t.TempDir()
	writeDiskstats(t, dir, 100, 50)
	m := &DiskIOMeter{}
	if _, ok := m.Sample(dir, time.Now()); ok {
		t.Fatal("first Sample must prime and return ok=false")
	}
}

func TestDiskIOMeter_ComputesIOPS(t *testing.T) {
	dir := t.TempDir()
	t0 := time.Now()
	writeDiskstats(t, dir, 100, 50) // 150 ops
	m := &DiskIOMeter{}
	m.Sample(dir, t0) // prime

	writeDiskstats(t, dir, 200, 100) // +100 reads +50 writes = +150 ops over 10s
	io, ok := m.Sample(dir, t0.Add(10*time.Second))
	if !ok {
		t.Fatal("second Sample should return ok=true")
	}
	if io.Total != 15.0 { // 150 ops / 10s
		t.Errorf("Total IOPS = %v, want 15", io.Total)
	}
	if io.PerDevice["sda"] != 15.0 {
		t.Errorf("sda IOPS = %v, want 15", io.PerDevice["sda"])
	}
	if _, present := io.PerDevice["loop0"]; present {
		t.Error("loopback device must be filtered out")
	}
}

func TestDiskIOMeter_IgnoresCounterReset(t *testing.T) {
	dir := t.TempDir()
	t0 := time.Now()
	writeDiskstats(t, dir, 500, 500)
	m := &DiskIOMeter{}
	m.Sample(dir, t0)
	writeDiskstats(t, dir, 10, 10) // counter went backwards (reboot)
	io, ok := m.Sample(dir, t0.Add(10*time.Second))
	if !ok {
		t.Fatal("ok should be true")
	}
	if io.Total != 0 {
		t.Errorf("counter reset must yield 0 IOPS, got %v", io.Total)
	}
}
