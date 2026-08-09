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

func TestWholeDisks_ExcludesPartitions(t *testing.T) {
	w := wholeDisks([]string{"sda", "sda1", "sda2", "sdb", "nvme0n1", "nvme0n1p1", "loop0", "dm-0"})
	for _, want := range []string{"sda", "sdb", "nvme0n1"} {
		if !w[want] {
			t.Errorf("%s should be a whole disk", want)
		}
	}
	for _, notWant := range []string{"sda1", "sda2", "nvme0n1p1", "loop0", "dm-0"} {
		if w[notWant] {
			t.Errorf("%s must be excluded (partition/virtual)", notWant)
		}
	}
}

// The LINSTOR hazard: minors are handed out freely, so drbd100 and drbd1000 can
// coexist. Under the old plain-prefix rule drbd1000 counted as "a partition of
// drbd100" and vanished from the metrics — losing a VM's disk silently.
func TestWholeDisks_NumericDeviceFamilies(t *testing.T) {
	w := wholeDisks([]string{"drbd100", "drbd1000", "drbd1001", "zd48", "zd48p1", "mmcblk0", "mmcblk0p1"})
	for _, want := range []string{"drbd100", "drbd1000", "drbd1001", "zd48", "mmcblk0"} {
		if !w[want] {
			t.Errorf("%s should be a whole device", want)
		}
	}
	for _, notWant := range []string{"zd48p1", "mmcblk0p1"} {
		if w[notWant] {
			t.Errorf("%s is a partition and must be excluded", notWant)
		}
	}
}

func TestIsStackedDevice(t *testing.T) {
	for _, dev := range []string{"drbd1000", "zd48", "md0", "md127"} {
		if !isStackedDevice(dev) {
			t.Errorf("%s should count as a stacked layer", dev)
		}
	}
	// Real bottom-layer disks, plus near-misses that must not be swept up:
	// zram is memory-backed and not stacked on a disk, and no partition suffix
	// makes a device virtual.
	for _, dev := range []string{"sda", "nvme0n1", "zram0", "sdz", "mdisk1"} {
		if isStackedDevice(dev) {
			t.Errorf("%s must not count as a stacked layer", dev)
		}
	}
}

// The server total must skip stacked layers while the per-device breakdown keeps
// them — the exact shape measured on vpp0221 (drbd on top of a physical disk).
func TestDiskIOMeter_TotalExcludesStackedLayers(t *testing.T) {
	dir := t.TempDir()
	write := func(sdaOps, drbdOps uint64) {
		t.Helper()
		line := "   8       0 sda " + itoa(sdaOps) + " 0 100 50 0 0 200 60 0 0 0\n" +
			" 147    1000 drbd1000 " + itoa(drbdOps) + " 0 100 50 0 0 200 60 0 0 0\n"
		if err := os.WriteFile(filepath.Join(dir, "diskstats"), []byte(line), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t0 := time.Now()
	write(0, 0)
	m := &DiskIOMeter{}
	m.Sample(dir, t0)

	write(300, 100)                                 // 30 IOPS physical, 10 IOPS through DRBD — of which the
	io, ok := m.Sample(dir, t0.Add(10*time.Second)) // 10 also passed through sda
	if !ok {
		t.Fatal("ok should be true")
	}
	if io.Total != 30.0 {
		t.Errorf("Total = %v, want 30 (physical only, no double count)", io.Total)
	}
	if io.PerDevice["drbd1000"] != 10.0 {
		t.Errorf("drbd1000 = %v, want 10 — the per-VM view must survive", io.PerDevice["drbd1000"])
	}
}

func TestDiskIOMeter_ComputesAwait(t *testing.T) {
	dir := t.TempDir()
	t0 := time.Now()
	// sda: reads=100 ms_read=1000 writes=0 ms_write=0
	line1 := "   8       0 sda 100 0 500 1000 0 0 0 0 0 0 0\n"
	os.WriteFile(filepath.Join(dir, "diskstats"), []byte(line1), 0o644)
	m := &DiskIOMeter{}
	m.Sample(dir, t0) // prime
	// +100 reads, +500ms service time → await = 500/100 = 5 ms/IO
	line2 := "   8       0 sda 200 0 900 1500 0 0 0 0 0 0 0\n"
	os.WriteFile(filepath.Join(dir, "diskstats"), []byte(line2), 0o644)
	io, ok := m.Sample(dir, t0.Add(10*time.Second))
	if !ok {
		t.Fatal("ok should be true")
	}
	if io.AwaitMs != 5.0 {
		t.Errorf("AwaitMs = %v, want 5", io.AwaitMs)
	}
	if io.PerDeviceAwait["sda"] != 5.0 {
		t.Errorf("sda await = %v, want 5", io.PerDeviceAwait["sda"])
	}
}
