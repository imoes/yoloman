package inventory

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// buildFakeSystem lays out a minimal /proc + /sys + os-release tree
// mirroring a real KVM guest (values taken from a live QEMU host).
func buildFakeSystem(t *testing.T) *Collector {
	t.Helper()
	root := t.TempDir()
	write := func(rel, content string) {
		t.Helper()
		path := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	write("proc/cpuinfo", `processor	: 0
vendor_id	: GenuineIntel
model name	: Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
cpu MHz		: 1999.999
cache size	: 16384 KB
physical id	: 0
cpu cores	: 2

processor	: 1
vendor_id	: GenuineIntel
model name	: Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
cpu MHz		: 1999.999
cache size	: 16384 KB
physical id	: 0
cpu cores	: 2

processor	: 2
vendor_id	: GenuineIntel
model name	: Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
cpu MHz		: 1999.999
cache size	: 16384 KB
physical id	: 1
cpu cores	: 2

processor	: 3
vendor_id	: GenuineIntel
model name	: Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
cpu MHz		: 1999.999
cache size	: 16384 KB
physical id	: 1
cpu cores	: 2
`)
	write("proc/meminfo", "MemTotal:        2029612 kB\nMemFree:          181724 kB\n")
	write("proc/sys/kernel/osrelease", "6.12.94-generic\n")
	write("etc/os-release", "NAME=\"Debian GNU/Linux\"\nVERSION_ID=\"13\"\nID=debian\nPRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nVERSION_CODENAME=trixie\n")

	// DMI (product_serial present = running as root; board_* absent like QEMU)
	write("sys/class/dmi/id/sys_vendor", "QEMU\n")
	write("sys/class/dmi/id/product_name", "Standard PC (i440FX + PIIX, 1996)\n")
	write("sys/class/dmi/id/product_serial", "SN-12345\n")
	write("sys/class/dmi/id/product_uuid", "a5086ece-1a09-4855-9f00-000000000000\n")
	write("sys/class/dmi/id/chassis_type", "1\n")
	write("sys/class/dmi/id/bios_vendor", "Proxmox distribution of EDK II\n")
	write("sys/class/dmi/id/bios_version", "4.2025.05-2\n")
	write("sys/class/dmi/id/bios_date", "11/13/2025\n")

	// Disks: one real virtio disk, plus loop/dm noise that must be skipped
	write("sys/block/vda/size", "125829120\n") // 60 GiB in 512-byte sectors
	write("sys/block/vda/queue/rotational", "0\n")
	write("sys/block/vda/serial", "drive-scsi0\n")
	write("sys/block/loop0/size", "8\n")
	write("sys/block/dm-0/size", "999\n")

	// NICs: one real, one bridge, plus lo and veth noise
	write("sys/class/net/ens18/address", "aa:bb:cc:dd:ee:ff\n")
	write("sys/class/net/ens18/operstate", "up\n")
	write("sys/class/net/ens18/mtu", "1500\n")
	write("sys/class/net/ens18/speed", "10000\n")
	write("sys/class/net/br-docker/address", "c6:b1:ba:4f:73:39\n")
	write("sys/class/net/br-docker/operstate", "down\n")
	write("sys/class/net/br-docker/mtu", "1500\n")
	write("sys/class/net/br-docker/speed", "-1\n") // down link: must be omitted
	write("sys/class/net/lo/address", "00:00:00:00:00:00\n")
	write("sys/class/net/veth1234/address", "02:42:ac:11:00:02\n")

	return &Collector{
		ProcRoot:      filepath.Join(root, "proc"),
		SysRoot:       filepath.Join(root, "sys"),
		OSReleasePath: filepath.Join(root, "etc/os-release"),
		HostnameFunc:  func() (string, error) { return "test-host", nil },
	}
}

func TestCollect_FullInventory(t *testing.T) {
	inv := buildFakeSystem(t).Collect()

	// System / DMI
	if inv.System.Manufacturer != "QEMU" {
		t.Errorf("manufacturer: %q", inv.System.Manufacturer)
	}
	if inv.System.SerialNumber != "SN-12345" {
		t.Errorf("serial: %q", inv.System.SerialNumber)
	}
	if inv.System.ChassisType != "Other" {
		t.Errorf("chassis: %q", inv.System.ChassisType)
	}
	if inv.System.Virtualization != "kvm" {
		t.Errorf("virtualization: %q", inv.System.Virtualization)
	}
	if inv.BIOS.Version != "4.2025.05-2" {
		t.Errorf("bios version: %q", inv.BIOS.Version)
	}
	// board_* files absent → empty Board, no error
	if inv.Board.Vendor != "" || inv.Board.Serial != "" {
		t.Errorf("expected empty board, got %+v", inv.Board)
	}

	// CPU topology: 2 sockets × 2 cores, 4 threads
	if inv.CPU.Model != "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz" {
		t.Errorf("cpu model: %q", inv.CPU.Model)
	}
	if inv.CPU.Sockets != 2 || inv.CPU.Cores != 4 || inv.CPU.Threads != 4 {
		t.Errorf("topology: sockets=%d cores=%d threads=%d", inv.CPU.Sockets, inv.CPU.Cores, inv.CPU.Threads)
	}

	if inv.MemoryMB != 1982 {
		t.Errorf("memory_mb: %d", inv.MemoryMB)
	}

	// OS
	if inv.OS.Distribution != "Debian GNU/Linux" || inv.OS.Version != "13" || inv.OS.Codename != "trixie" {
		t.Errorf("os: %+v", inv.OS)
	}
	if inv.OS.Kernel != "6.12.94-generic" || inv.OS.Hostname != "test-host" {
		t.Errorf("kernel/hostname: %q/%q", inv.OS.Kernel, inv.OS.Hostname)
	}

	// Disks: only vda survives the noise filter
	if len(inv.Disks) != 1 {
		t.Fatalf("disks: %+v", inv.Disks)
	}
	d := inv.Disks[0]
	if d.Name != "vda" || d.SizeBytes != 125829120*512 || d.Serial != "drive-scsi0" || d.Rotational {
		t.Errorf("disk: %+v", d)
	}

	// NICs: ens18 + br-docker; lo and veth filtered; -1 speed omitted
	if len(inv.NICs) != 2 {
		t.Fatalf("nics: %+v", inv.NICs)
	}
	if inv.NICs[0].Name != "br-docker" || inv.NICs[0].SpeedMbps != 0 {
		t.Errorf("bridge nic: %+v", inv.NICs[0])
	}
	if inv.NICs[1].Name != "ens18" || inv.NICs[1].MAC != "aa:bb:cc:dd:ee:ff" || inv.NICs[1].SpeedMbps != 10000 {
		t.Errorf("ens18: %+v", inv.NICs[1])
	}
}

func TestCollect_EmptySystemIsNotAnError(t *testing.T) {
	// A collector pointed at empty roots must still return a usable
	// document (arch + collected_at), never panic or error.
	root := t.TempDir()
	c := &Collector{
		ProcRoot:      filepath.Join(root, "proc"),
		SysRoot:       filepath.Join(root, "sys"),
		OSReleasePath: filepath.Join(root, "etc/os-release"),
		HostnameFunc:  os.Hostname,
	}
	inv := c.Collect()
	if inv.CPU.Arch == "" || inv.CollectedAt == "" {
		t.Errorf("expected arch + timestamp, got %+v", inv)
	}
}

func TestCached_RefreshesAfterTTL(t *testing.T) {
	c := buildFakeSystem(t)
	cached := NewCached(c, 50*time.Millisecond)
	first := cached.Get()
	if cached.Get() != first {
		t.Fatal("expected the cached pointer inside the TTL")
	}
	time.Sleep(60 * time.Millisecond)
	if cached.Get() == first {
		t.Fatal("expected a refreshed inventory after the TTL")
	}
}
