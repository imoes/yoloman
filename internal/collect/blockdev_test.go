package collect

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/store"
)

// fakeDev builds the two udev symlink trees the scanner reads, mirroring a real
// Proxmox host: a LINSTOR/DRBD storage plus a local ZFS pool.
func fakeDev(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	link := func(rel, target string) {
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, full); err != nil {
			t.Fatal(err)
		}
	}
	// DRBD: by-res/<resource>/<volume-number> → ../../drbdNNNN
	link("drbd/by-res/pm-95db8b13_221103/0", "../../drbd1000")
	link("drbd/by-res/pm-573e2517_221101/0", "../../drbd1001")
	link("drbd/by-res/scratch/0", "../../drbd1002") // no id in the name
	// ZFS: nested dataset paths, plus a partition link udev also creates
	link("zvol/rpool/data/vm-100-disk-0", "../../../zd48")
	link("zvol/rpool/data/vm-100-disk-0-part1", "../../../zd48p1")
	link("zvol/rpool/data/subvol-131-disk-0", "../../../zd64")
	return root
}

func TestScanDeviceOwners(t *testing.T) {
	owners := ScanDeviceOwners(fakeDev(t))

	for dev, want := range map[string]DeviceOwner{
		"drbd1000": {VM: "221103", Volume: "pm-95db8b13_221103"},
		"drbd1001": {VM: "221101", Volume: "pm-573e2517_221101"},
		"drbd1002": {VM: "", Volume: "scratch"},
		"zd48":     {VM: "100", Volume: "rpool/data/vm-100-disk-0"},
		"zd64":     {VM: "131", Volume: "rpool/data/subvol-131-disk-0"},
	} {
		if got := owners[dev]; got != want {
			t.Errorf("%s: got %+v, want %+v", dev, got, want)
		}
	}
}

// A plain server has neither tree — the scanner must return empty, not blow up,
// because that is the common case across the fleet.
func TestScanDeviceOwnersNoTrees(t *testing.T) {
	if owners := ScanDeviceOwners(t.TempDir()); len(owners) != 0 {
		t.Fatalf("expected no owners, got %+v", owners)
	}
}

// fakePVE writes guest configs in Proxmox's own layout and wording, copied from
// vpp0221's live configs — including the LINSTOR naming where the host-side DRBD
// resource is only a PREFIX of the Proxmox volume name.
func fakePVE(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	write := func(rel, body string) {
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("qemu-server/221103.conf", `boot: order=scsi0
ide2: none,media=cdrom
name: host.example.internal
scsi0: linstor:pm-95db8b13_221103,iothread=1,size=200G
scsihw: virtio-scsi-single
`)
	write("qemu-server/221101.conf", `name: host.example.internal
scsi0: linstor:pm-573e2517_221101,discard=on,iothread=1,size=32G
scsi1: linstor:pm-bb2a3396_221101,discard=on,iothread=1,size=60G
unused0: local-zfs:vm-221101-disk-9
[snapshot-before-upgrade]
scsi0: linstor:pm-573e2517_221101,discard=on,iothread=1,size=32G
`)
	write("lxc/131.conf", `hostname: ct131
rootfs: local-zfs:subvol-131-disk-0,size=8G
mp0: local-zfs:subvol-131-disk-1,mp=/data,size=50G
`)
	write("qemu-server/notes.txt", "ignored") // not a <vmid>.conf
	// A guest running on ANOTHER node. Its DRBD replica still lives on this host
	// and still costs local I/O, so its config must be read too.
	write("nodes/vpp0223/qemu-server/223104.conf", `name: host4.example.internal
scsi0: linstor:pm-121314d1_223104,iothread=1,size=100G
`)
	return root
}

func TestProxmoxGuestVolumes(t *testing.T) {
	got := ProxmoxGuestVolumes(fakePVE(t))
	want := map[string]string{
		"pm-95db8b13_221103": "221103",
		"pm-573e2517_221101": "221101",
		"pm-bb2a3396_221101": "221101",
		"vm-221101-disk-9":   "221101",
		"subvol-131-disk-0":  "131",
		"subvol-131-disk-1":  "131",
		"pm-121314d1_223104": "223104", // from nodes/vpp0223 — a guest on another node
	}
	for vol, id := range want {
		if got[vol] != id {
			t.Errorf("%s: got %q, want %q", vol, got[vol], id)
		}
	}
	if len(got) != len(want) {
		t.Errorf("extra entries: got %+v", got)
	}
	// An empty CDROM must not be mistaken for a volume.
	if _, ok := got["none"]; ok {
		t.Error("`ide2: none,media=cdrom` was read as a volume")
	}
}

func TestProxmoxGuestVolumesNotAProxmoxHost(t *testing.T) {
	if got := ProxmoxGuestVolumes(filepath.Join(t.TempDir(), "etc", "pve")); len(got) != 0 {
		t.Fatalf("expected empty, got %+v", got)
	}
}

// The case the live cluster taught us: the DRBD resource is pm-95db8b13, the
// Proxmox volume is pm-95db8b13_221103, and only joining the two yields the id.
func TestResolveDeviceOwnersJoinsProxmoxNaming(t *testing.T) {
	devRoot := t.TempDir()
	link := func(rel, target string) {
		full := filepath.Join(devRoot, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, full); err != nil {
			t.Fatal(err)
		}
	}
	link("drbd/by-res/pm-95db8b13/0", "../../drbd1003")
	link("drbd/by-res/pm-unknown/0", "../../drbd1009") // no guest claims it
	link("zvol/rpool/data/subvol-131-disk-0", "../../../zd64")

	owners := ResolveDeviceOwners(devRoot, fakePVE(t))

	if got := owners["drbd1003"]; got.VM != "221103" || got.Volume != "pm-95db8b13" {
		t.Errorf("drbd1003: got %+v, want vm 221103 / volume pm-95db8b13", got)
	}
	// Unclaimed volumes keep their name and stay id-less rather than guessing.
	if got := owners["drbd1009"]; got.VM != "" || got.Volume != "pm-unknown" {
		t.Errorf("drbd1009: got %+v, want no vm", got)
	}
	// The device tree already carried this one — the join must not disturb it.
	if got := owners["zd64"]; got.VM != "131" {
		t.Errorf("zd64: got %+v, want vm 131", got)
	}
}

func TestVMIDFromVolume(t *testing.T) {
	cases := map[string]string{
		"pm-95db8b13_221103":  "221103",
		"vm-100-disk-0":       "100",
		"base-9000-disk-0":    "9000",
		"subvol-131-disk-0":   "131",
		"scratch":             "",
		"backup_archive":      "", // suffix isn't numeric
		"vm-disk-0":           "", // no id where one is expected
		"pm-95db8b13_221103a": "",
	}
	for in, want := range cases {
		if got := vmIDFromVolume(in); got != want {
			t.Errorf("%q: got %q, want %q", in, got, want)
		}
	}
}

func TestLabelDeviceOwners(t *testing.T) {
	shared := map[string]string{"device": "drbd1000"}
	points := []store.Point{
		{Metric: "disk_reads_total", Labels: shared},
		{Metric: "disk_writes_total", Labels: shared}, // same map as above, as Sample does
		{Metric: "disk_iops_device", Labels: map[string]string{"device": "nvme0n1"}},
		{Metric: "cpu_pct"}, // no device label at all
	}
	owners := map[string]DeviceOwner{"drbd1000": {VM: "221103", Volume: "pm-95db8b13_221103"}}

	out := LabelDeviceOwners(points, owners)

	for _, i := range []int{0, 1} {
		if out[i].Labels["vm"] != "221103" || out[i].Labels["volume"] != "pm-95db8b13_221103" {
			t.Errorf("point %d not labelled: %+v", i, out[i].Labels)
		}
		if out[i].Labels["device"] != "drbd1000" {
			t.Errorf("point %d lost its device label: %+v", i, out[i].Labels)
		}
	}
	// The map Sample shared between those two points must not have been mutated.
	if _, leaked := shared["vm"]; leaked {
		t.Error("the shared label map was mutated in place")
	}
	// A device with no owner keeps its labels, and a point with no device is untouched.
	if _, ok := out[2].Labels["vm"]; ok {
		t.Errorf("unowned device got a vm label: %+v", out[2].Labels)
	}
	if out[3].Labels != nil {
		t.Errorf("label-less point got labels: %+v", out[3].Labels)
	}
}

// No owners (any non-hypervisor host) must be a no-op, not a rebuild.
func TestLabelDeviceOwnersEmpty(t *testing.T) {
	points := []store.Point{{Metric: "disk_iops_device", Labels: map[string]string{"device": "sda"}}}
	out := LabelDeviceOwners(points, nil)
	if len(out[0].Labels) != 1 {
		t.Fatalf("labels changed: %+v", out[0].Labels)
	}
}
