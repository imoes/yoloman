package collect

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/mutkluge/agentic-mcp/internal/store"
)

// DeviceOwner names the guest a block device belongs to.
//
// The IOPS question an operator actually asks on a hypervisor is "which VM is
// saturating this disk", and /proc/diskstats cannot answer it: it knows drbd1000
// and zd48, never vmid 221103. The mapping exists on the host anyway, in the udev
// symlink trees that DRBD and ZFS maintain, so the agent resolves it locally —
// no Proxmox API call, no credentials, nothing to reach over the network.
type DeviceOwner struct {
	VM     string // the guest id ("221103"), empty when the volume name carries none
	Volume string // the DRBD resource / zvol dataset the device backs
}

// ResolveDeviceOwners is the full resolution: the udev symlink trees give
// device → volume, and Proxmox's guest configs give volume → guest id.
//
// The second step is needed because the two sides name the same volume
// differently, which only showed up against the live cluster: Proxmox's config
// says `scsi0: linstor:pm-95db8b13_221103`, but the DRBD resource on the host is
// just `pm-95db8b13` — LINSTOR never sees the `_221103`. So the id cannot be read
// off the device tree alone for DRBD storage, and the guest configs are the local,
// authoritative place that holds both halves.
func ResolveDeviceOwners(devRoot, pveRoot string) map[string]DeviceOwner {
	owners := ScanDeviceOwners(devRoot)
	if len(owners) == 0 {
		return owners
	}
	guests := ProxmoxGuestVolumes(pveRoot)
	if len(guests) == 0 {
		return owners
	}
	for dev, o := range owners {
		if o.VM != "" || o.Volume == "" {
			continue
		}
		if id := guestOfVolume(guests, filepath.Base(o.Volume)); id != "" {
			o.VM = id
			owners[dev] = o
		}
	}
	return owners
}

// guestOfVolume matches a host-side volume name against the Proxmox volume
// names, exactly or as the prefix Proxmox extends with "_<vmid>".
func guestOfVolume(guests map[string]string, volume string) string {
	if id, ok := guests[volume]; ok {
		return id
	}
	for name, id := range guests {
		if strings.HasPrefix(name, volume+"_") {
			return id
		}
	}
	// A LINSTOR-backed zvol is named `<resource>_<volume-index>`, and the guest configs know only the
	// resource: the dataset `pm-121314d1_00000` belongs to whichever guest owns `pm-121314d1`, which is
	// also what drbd1000 resolves to. Strip the index and ask again, so the zvol and the DRBD device
	// sitting on top of it agree about their guest instead of one of them going unattributed.
	if i := strings.LastIndex(volume, "_"); i > 0 && allDigits(volume[i+1:]) {
		base := volume[:i]
		if id, ok := guests[base]; ok {
			return id
		}
		for name, id := range guests {
			if strings.HasPrefix(name, base+"_") {
				return id
			}
		}
	}
	return ""
}

// ProxmoxGuestVolumes maps every volume named in a guest's config to that guest's
// id, reading <vmid>.conf files from the whole cluster config, not just this node.
//
// Cluster-wide on purpose: DRBD replicates, so a node carries devices for guests
// that RUN elsewhere, and their replica writes are real local disk load. Reading
// only pveRoot/qemu-server (this node's guests) left 5 of 9 DRBD devices on
// vpp0221 without an id — exactly the ones whose load an operator would otherwise
// be unable to attribute at all.
//
// Empty (and cheap) on any host that isn't a Proxmox node.
func ProxmoxGuestVolumes(pveRoot string) map[string]string {
	out := map[string]string{}
	// pveRoot/<kind> is this node (a symlink into nodes/<self>), pveRoot/nodes/*/<kind>
	// is every node. Overlapping entries are identical, so the duplication is free.
	dirs := []string{pveRoot}
	if nodes, err := os.ReadDir(filepath.Join(pveRoot, "nodes")); err == nil {
		for _, n := range nodes {
			dirs = append(dirs, filepath.Join(pveRoot, "nodes", n.Name()))
		}
	}
	for _, dir := range dirs {
		for _, kind := range []string{"qemu-server", "lxc"} {
			readGuestDir(filepath.Join(dir, kind), out)
		}
	}
	return out
}

func readGuestDir(dir string, out map[string]string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		id := strings.TrimSuffix(e.Name(), ".conf")
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".conf") || !allDigits(id) {
			continue
		}
		body, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		for _, vol := range guestConfigVolumes(string(body)) {
			out[vol] = id
		}
	}
}

// diskKeyPrefixes are the config keys that carry a disk. `rootfs` is LXC's;
// the rest are QEMU bus names, plus the two state volumes.
var diskKeyPrefixes = []string{"scsi", "virtio", "ide", "sata", "rootfs", "mp", "efidisk", "tpmstate", "unused"}

// guestConfigVolumes pulls the volume names out of a Proxmox guest config.
// A disk line reads `scsi0: <storage>:<volume>,opt=val,...`; a CDROM reads
// `ide2: none,media=cdrom` and yields nothing.
//
// Snapshots appear in the same file under [name] sections and repeat the same
// volumes, which is harmless — the map is volume → id either way. A section
// header is not skipped for that reason alone.
func guestConfigVolumes(body string) []string {
	var out []string
	for _, line := range strings.Split(body, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok || !hasAnyPrefix(key, diskKeyPrefixes) {
			continue
		}
		spec, _, _ := strings.Cut(strings.TrimSpace(value), ",")
		_, volume, ok := strings.Cut(spec, ":")
		if !ok || volume == "" {
			continue // `none` (empty CDROM) or a bare option, not a volume
		}
		out = append(out, filepath.Base(volume))
	}
	return out
}

func hasAnyPrefix(s string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// ScanDeviceOwners maps kernel device names (as they appear in /proc/diskstats)
// to the guest that owns them, by reading two symlink trees under devRoot:
//
//	/dev/drbd/by-res/<resource>/<volume>  →  ../../drbd1000
//	/dev/zvol/<pool>/<dataset>            →  ../../zd48
//
// Missing trees are not an error — a plain server has neither, and gets an empty
// map, which leaves every disk series exactly as it was.
func ScanDeviceOwners(devRoot string) map[string]DeviceOwner {
	out := map[string]DeviceOwner{}
	scanDRBD(filepath.Join(devRoot, "drbd", "by-res"), out)
	scanZvol(filepath.Join(devRoot, "zvol"), out)
	return out
}

// scanDRBD reads /dev/drbd/by-res/<resource>/<volume-number>. The resource name
// is what LINSTOR/Proxmox names the volume, e.g. "pm-95db8b13_221103".
func scanDRBD(root string, out map[string]DeviceOwner) {
	resources, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, res := range resources {
		vols, err := os.ReadDir(filepath.Join(root, res.Name()))
		if err != nil {
			continue
		}
		for _, v := range vols {
			dev, ok := linkTarget(filepath.Join(root, res.Name(), v.Name()))
			if !ok {
				continue
			}
			out[dev] = DeviceOwner{VM: vmIDFromVolume(res.Name()), Volume: res.Name()}
		}
	}
}

// scanZvol walks /dev/zvol, whose depth follows the ZFS dataset hierarchy
// (rpool/data/vm-100-disk-0). The dataset path relative to /dev/zvol is the
// volume name.
func scanZvol(root string, out map[string]DeviceOwner) {
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil //nolint:nilerr // an unreadable subtree is skipped, not fatal
		}
		dev, ok := linkTarget(path)
		if !ok {
			return nil
		}
		vol, relErr := filepath.Rel(root, path)
		if relErr != nil {
			return nil
		}
		out[dev] = DeviceOwner{VM: vmIDFromVolume(filepath.Base(vol)), Volume: vol}
		return nil
	})
}

// linkTarget resolves a udev symlink to the bare kernel device name it points
// at ("../../drbd1000" → "drbd1000"). Non-symlinks are ignored.
func linkTarget(path string) (string, bool) {
	target, err := os.Readlink(path)
	if err != nil {
		return "", false
	}
	name := filepath.Base(target)
	if name == "" || name == "." || name == "/" {
		return "", false
	}
	return name, true
}

// vmIDFromVolume digs the guest id out of a storage volume name. Two naming
// schemes cover Proxmox:
//
//	pm-95db8b13_221103        LINSTOR/DRBD — id is the suffix
//	vm-100-disk-0             ZFS/LVM; also base-100-disk-0 (template) and
//	                          subvol-100-disk-0 (LXC)
//
// Returns "" for anything else — a volume that isn't a guest's (or a scheme we
// don't know) then carries only its name, never a guessed id.
func vmIDFromVolume(name string) string {
	if i := strings.LastIndex(name, "_"); i >= 0 {
		if id := name[i+1:]; allDigits(id) && !isPaddedIndex(id) {
			return id
		}
	}
	for _, prefix := range []string{"vm-", "base-", "subvol-"} {
		if !strings.HasPrefix(name, prefix) {
			continue
		}
		rest := name[len(prefix):]
		if i := strings.Index(rest, "-"); i > 0 && allDigits(rest[:i]) {
			return rest[:i]
		}
	}
	return ""
}

// isPaddedIndex tells a LINSTOR volume index from a Proxmox guest id.
//
// LINSTOR names the ZFS dataset backing volume N of a resource `<resource>_<N>`, zero-padded to five
// digits: `drbd-zfs-pool/pm-121314d1_00000`. A Proxmox VMID is a plain decimal from 100 upwards and
// therefore never carries a leading zero, so the padding is the whole distinction.
//
// Without this, `_00000` was read as the guest id — and because the id was then non-empty,
// ResolveDeviceOwners skipped the guest-config join that would have found the real one. Measured on
// vpp0222: five unrelated zvols (pm-121314d1, pm-4eec6e95, pm-573e2517, pm-bb2a3396 …) all reported
// `vm=00000`, a guest that does not exist, collapsed into one. "Which VM saturates nvme0n1" answered
// with a fabricated VM is worse than leaving it unanswered.
func isPaddedIndex(s string) bool {
	return len(s) > 1 && s[0] == '0'
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// LabelDeviceOwners annotates every point carrying a `device` label with the
// guest that device belongs to, so "which VM saturates nvme0n1" becomes a
// query rather than an investigation.
//
// Applied as one pass over the finished points instead of threading owners
// through Sample and DiskIOMeter separately — both produce device-labelled
// series and both must agree. Labels are copied rather than extended in place:
// Sample builds ONE label map per device and shares it across six counter
// points, and silently mutating shared state is how those six drift apart later.
//
// Adds no series to a host without guests (no owners → returned unchanged), and
// adds no cardinality where it does apply: the same series, richer labels.
func LabelDeviceOwners(points []store.Point, owners map[string]DeviceOwner) []store.Point {
	if len(owners) == 0 {
		return points
	}
	for i, p := range points {
		dev := p.Labels["device"]
		if dev == "" {
			continue
		}
		owner, ok := owners[dev]
		if !ok || owner.Volume == "" {
			continue
		}
		labels := make(map[string]string, len(p.Labels)+2)
		for k, v := range p.Labels {
			labels[k] = v
		}
		labels["volume"] = owner.Volume
		if owner.VM != "" {
			labels["vm"] = owner.VM
		}
		points[i].Labels = labels
	}
	return points
}
