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
		if id := name[i+1:]; allDigits(id) {
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
