// Package inventory collects the host's hardware/software inventory — the
// CheckMK-HW/SW-inventory equivalent (see docs/plan.md, Block H1): CPU
// model, mainboard, serial numbers, BIOS, disks, NICs, OS. Everything is
// read from /proc, /sys/class/dmi/id, /sys/block, /sys/class/net and
// /etc/os-release — no dmidecode, no external binaries, keeping the
// zero-dependency promise. Unlike internal/collect (fast-changing
// time-series metrics, sampled every 30s), inventory is near-static
// descriptive data: collected once at startup and refreshed on a long
// TTL, shipped as one JSON document on GET /api/v1/hosts/overview.
//
// Missing or unreadable sources are simply omitted (VMs often expose no
// board_*; serial files are root-only): a partial inventory is normal,
// never an error.
package inventory

import (
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/proc"
)

// Inventory is the whole document. Sub-structs use omitempty everywhere so
// absent sources vanish from the JSON instead of rendering as "".
type Inventory struct {
	CollectedAt string `json:"collected_at"`
	System      System `json:"system"`
	Board       Board  `json:"board,omitempty"`
	BIOS        BIOS   `json:"bios,omitempty"`
	CPU         CPU    `json:"cpu"`
	MemoryMB    int64  `json:"memory_mb,omitempty"`
	OS          OS     `json:"os"`
	Disks       []Disk `json:"disks,omitempty"`
	NICs        []NIC  `json:"nics,omitempty"`
}

type System struct {
	Manufacturer   string `json:"manufacturer,omitempty"`   // dmi sys_vendor
	ProductName    string `json:"product_name,omitempty"`   // dmi product_name
	SerialNumber   string `json:"serial_number,omitempty"`  // dmi product_serial (root-only)
	UUID           string `json:"uuid,omitempty"`           // dmi product_uuid (root-only)
	Family         string `json:"family,omitempty"`         // dmi product_family
	Version        string `json:"version,omitempty"`        // dmi product_version
	ChassisType    string `json:"chassis_type,omitempty"`   // dmi chassis_type, mapped to the SMBIOS name
	Virtualization string `json:"virtualization,omitempty"` // derived: kvm/vmware/virtualbox/hyper-v/xen
}

type Board struct {
	Vendor  string `json:"vendor,omitempty"`
	Name    string `json:"name,omitempty"`
	Serial  string `json:"serial,omitempty"` // root-only
	Version string `json:"version,omitempty"`
}

type BIOS struct {
	Vendor  string `json:"vendor,omitempty"`
	Version string `json:"version,omitempty"`
	Date    string `json:"date,omitempty"`
	Release string `json:"release,omitempty"`
}

type CPU struct {
	Model   string `json:"model,omitempty"`  // cpuinfo "model name"
	Vendor  string `json:"vendor,omitempty"` // cpuinfo "vendor_id"
	Sockets int    `json:"sockets,omitempty"`
	Cores   int    `json:"cores,omitempty"` // physical cores across all sockets
	Threads int    `json:"threads"`         // logical processors
	MHz     string `json:"mhz,omitempty"`   // cpuinfo "cpu MHz" (current, informational)
	Cache   string `json:"cache,omitempty"` // cpuinfo "cache size"
	Arch    string `json:"architecture,omitempty"`
}

type OS struct {
	Distribution string `json:"distribution,omitempty"` // os-release NAME
	Version      string `json:"version,omitempty"`      // os-release VERSION_ID
	ID           string `json:"id,omitempty"`           // os-release ID
	IDLike       string `json:"id_like,omitempty"`      // os-release ID_LIKE (family hint)
	PrettyName   string `json:"pretty_name,omitempty"`
	Codename     string `json:"codename,omitempty"` // os-release VERSION_CODENAME
	Kernel       string `json:"kernel,omitempty"`
	Hostname     string `json:"hostname,omitempty"`
}

type Disk struct {
	Name       string `json:"name"`
	SizeBytes  int64  `json:"size_bytes,omitempty"`
	Model      string `json:"model,omitempty"`
	Serial     string `json:"serial,omitempty"`
	Rotational bool   `json:"rotational"`
}

type NIC struct {
	Name      string   `json:"name"`
	MAC       string   `json:"mac,omitempty"`
	State     string   `json:"state,omitempty"` // operstate
	MTU       int      `json:"mtu,omitempty"`
	SpeedMbps int      `json:"speed_mbps,omitempty"`
	IPv4      []string `json:"ipv4,omitempty"` // assigned IPv4 addresses (no CIDR suffix)
	IPv6      []string `json:"ipv6,omitempty"` // assigned global IPv6 (link-local fe80:: omitted)
}

// SMBIOS chassis type table (System Enclosure, type 3) — the common subset.
var chassisTypes = map[string]string{
	"1": "Other", "2": "Unknown", "3": "Desktop", "4": "Low Profile Desktop",
	"6": "Mini Tower", "7": "Tower", "8": "Portable", "9": "Laptop",
	"10": "Notebook", "13": "All-in-One", "17": "Main Server Chassis",
	"22": "Embedded PC", "23": "Rack Mount Chassis", "24": "Sealed-case PC",
	"31": "Convertible", "32": "Detachable",
}

// Collector reads the inventory from injectable roots — the same
// test-seam pattern as internal/modules/setup.go.
type Collector struct {
	ProcRoot      string // default /proc
	SysRoot       string // default /sys
	OSReleasePath string // default /etc/os-release
	HostnameFunc  func() (string, error)
	// NICAddrs returns a NIC's assigned IPv4/IPv6 addresses. IPs live in the
	// network stack, not under SysRoot, so this is a separate seam (default:
	// netNICAddrs, via net.InterfaceByName); tests inject a stub. nil = skip
	// address collection (older behavior).
	NICAddrs func(name string) (ipv4, ipv6 []string)
}

// DefaultCollector reads the real system.
func DefaultCollector() *Collector {
	return &Collector{
		ProcRoot: "/proc", SysRoot: "/sys", OSReleasePath: "/etc/os-release",
		HostnameFunc: os.Hostname, NICAddrs: netNICAddrs,
	}
}

// netNICAddrs reports a NIC's assigned addresses via the kernel network
// stack. IPv6 link-local (fe80::/10) is omitted — every interface has one and
// it carries no inventory value. CIDR suffixes are stripped to bare IPs.
func netNICAddrs(name string) (ipv4, ipv6 []string) {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return nil, nil
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return nil, nil
	}
	for _, a := range addrs {
		ipnet, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		if v4 := ipnet.IP.To4(); v4 != nil {
			ipv4 = append(ipv4, v4.String())
		} else if !ipnet.IP.IsLinkLocalUnicast() {
			ipv6 = append(ipv6, ipnet.IP.String())
		}
	}
	return ipv4, ipv6
}

// Collect assembles the full inventory. It never fails: unreadable
// sources are omitted.
func (c *Collector) Collect() *Inventory {
	inv := &Inventory{CollectedAt: time.Now().UTC().Format(time.RFC3339)}
	c.collectDMI(inv)
	c.collectCPU(inv)
	c.collectMemory(inv)
	c.collectOS(inv)
	inv.Disks = c.collectDisks()
	inv.NICs = c.collectNICs()
	inv.System.Virtualization = detectVirtualization(inv)
	return inv
}

func (c *Collector) dmi(name string) string {
	return readTrimmed(filepath.Join(c.SysRoot, "class/dmi/id", name))
}

func (c *Collector) collectDMI(inv *Inventory) {
	inv.System.Manufacturer = c.dmi("sys_vendor")
	inv.System.ProductName = c.dmi("product_name")
	inv.System.SerialNumber = c.dmi("product_serial")
	inv.System.UUID = c.dmi("product_uuid")
	inv.System.Family = c.dmi("product_family")
	inv.System.Version = c.dmi("product_version")
	if t := c.dmi("chassis_type"); t != "" {
		if name, ok := chassisTypes[t]; ok {
			inv.System.ChassisType = name
		} else {
			inv.System.ChassisType = t
		}
	}
	inv.Board = Board{
		Vendor:  c.dmi("board_vendor"),
		Name:    c.dmi("board_name"),
		Serial:  c.dmi("board_serial"),
		Version: c.dmi("board_version"),
	}
	inv.BIOS = BIOS{
		Vendor:  c.dmi("bios_vendor"),
		Version: c.dmi("bios_version"),
		Date:    c.dmi("bios_date"),
		Release: c.dmi("bios_release"),
	}
}

func (c *Collector) collectCPU(inv *Inventory) {
	inv.CPU.Arch = unameArch(runtime.GOARCH)
	f, err := os.Open(filepath.Join(c.ProcRoot, "cpuinfo"))
	if err != nil {
		return
	}
	defer f.Close()
	cpus, err := proc.ParseCPUInfo(f)
	if err != nil || len(cpus) == 0 {
		return
	}
	first := cpus[0]
	inv.CPU.Model = first["model name"]
	inv.CPU.Vendor = first["vendor_id"]
	inv.CPU.MHz = first["cpu MHz"]
	inv.CPU.Cache = first["cache size"]
	inv.CPU.Threads = len(cpus)

	// Sockets = distinct "physical id"s; physical cores = sockets ×
	// "cpu cores". Both fields are absent on some VMs — fall back to
	// thread count so the inventory never reads zero cores.
	sockets := map[string]bool{}
	for _, cpu := range cpus {
		if id, ok := cpu["physical id"]; ok {
			sockets[id] = true
		}
	}
	inv.CPU.Sockets = len(sockets)
	if inv.CPU.Sockets == 0 {
		inv.CPU.Sockets = 1
	}
	if coresStr, ok := first["cpu cores"]; ok {
		if cores, err := strconv.Atoi(coresStr); err == nil && cores > 0 {
			inv.CPU.Cores = inv.CPU.Sockets * cores
		}
	}
	if inv.CPU.Cores == 0 {
		inv.CPU.Cores = inv.CPU.Threads
	}
}

func (c *Collector) collectMemory(inv *Inventory) {
	f, err := os.Open(filepath.Join(c.ProcRoot, "meminfo"))
	if err != nil {
		return
	}
	defer f.Close()
	mem, err := proc.ParseMemInfo(f)
	if err != nil {
		return
	}
	if kb, ok := mem["MemTotal"]; ok {
		inv.MemoryMB = kb / 1024
	}
}

func (c *Collector) collectOS(inv *Inventory) {
	inv.OS.Kernel = readTrimmed(filepath.Join(c.ProcRoot, "sys/kernel/osrelease"))
	if c.HostnameFunc != nil {
		if hn, err := c.HostnameFunc(); err == nil {
			inv.OS.Hostname = hn
		}
	}
	data, err := os.ReadFile(c.OSReleasePath)
	if err != nil {
		return
	}
	kv := parseOSRelease(string(data))
	inv.OS.Distribution = kv["NAME"]
	inv.OS.Version = kv["VERSION_ID"]
	inv.OS.ID = kv["ID"]
	inv.OS.IDLike = kv["ID_LIKE"]
	inv.OS.PrettyName = kv["PRETTY_NAME"]
	inv.OS.Codename = kv["VERSION_CODENAME"]
}

// virtual/pseudo block devices that carry no inventory value.
var skipDiskPrefixes = []string{"loop", "ram", "zram", "dm-", "md", "fd", "sr"}

func (c *Collector) collectDisks() []Disk {
	entries, err := os.ReadDir(filepath.Join(c.SysRoot, "block"))
	if err != nil {
		return nil
	}
	var disks []Disk
	for _, e := range entries {
		name := e.Name()
		skip := false
		for _, p := range skipDiskPrefixes {
			if strings.HasPrefix(name, p) {
				skip = true
				break
			}
		}
		if skip {
			continue
		}
		base := filepath.Join(c.SysRoot, "block", name)
		d := Disk{
			Name:       name,
			Model:      readTrimmed(filepath.Join(base, "device/model")),
			Rotational: readTrimmed(filepath.Join(base, "queue/rotational")) == "1",
		}
		// virtio exposes the serial at <dev>/serial, SCSI at device/serial.
		d.Serial = readTrimmed(filepath.Join(base, "serial"))
		if d.Serial == "" {
			d.Serial = readTrimmed(filepath.Join(base, "device/serial"))
		}
		if sectors, err := strconv.ParseInt(readTrimmed(filepath.Join(base, "size")), 10, 64); err == nil {
			d.SizeBytes = sectors * 512
		}
		disks = append(disks, d)
	}
	sort.Slice(disks, func(i, j int) bool { return disks[i].Name < disks[j].Name })
	return disks
}

func (c *Collector) collectNICs() []NIC {
	entries, err := os.ReadDir(filepath.Join(c.SysRoot, "class/net"))
	if err != nil {
		return nil
	}
	var nics []NIC
	for _, e := range entries {
		name := e.Name()
		// lo is meaningless; veth* are container ephemera that would spam
		// a docker host's inventory. Bridges/bonds stay — they carry real
		// network identity.
		if name == "lo" || strings.HasPrefix(name, "veth") {
			continue
		}
		base := filepath.Join(c.SysRoot, "class/net", name)
		n := NIC{
			Name:  name,
			MAC:   readTrimmed(filepath.Join(base, "address")),
			State: readTrimmed(filepath.Join(base, "operstate")),
		}
		if mtu, err := strconv.Atoi(readTrimmed(filepath.Join(base, "mtu"))); err == nil {
			n.MTU = mtu
		}
		// speed reads -1 on down/virtual links and EINVALs on some
		// drivers; only positive values are meaningful.
		if speed, err := strconv.Atoi(readTrimmed(filepath.Join(base, "speed"))); err == nil && speed > 0 {
			n.SpeedMbps = speed
		}
		if c.NICAddrs != nil {
			n.IPv4, n.IPv6 = c.NICAddrs(name)
		}
		nics = append(nics, n)
	}
	sort.Slice(nics, func(i, j int) bool { return nics[i].Name < nics[j].Name })
	return nics
}

// detectVirtualization derives the hypervisor from DMI identity strings —
// the same heuristic every inventory tool uses (systemd-detect-virt reads
// the same fields).
func detectVirtualization(inv *Inventory) string {
	s := strings.ToLower(inv.System.Manufacturer + " " + inv.System.ProductName + " " + inv.BIOS.Vendor)
	switch {
	case strings.Contains(s, "qemu") || strings.Contains(s, "kvm") || strings.Contains(s, "proxmox"):
		return "kvm"
	case strings.Contains(s, "vmware"):
		return "vmware"
	case strings.Contains(s, "virtualbox"):
		return "virtualbox"
	case strings.Contains(s, "microsoft corporation virtual"):
		return "hyper-v"
	case strings.Contains(s, "xen"):
		return "xen"
	}
	return ""
}

func readTrimmed(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// parseOSRelease parses KEY=VALUE lines, stripping optional quotes — the
// same format internal/modules/setup.go handles; duplicated here so the
// inventory package stays free of the modules package (and vice versa).
func parseOSRelease(content string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		out[k] = strings.Trim(v, `"'`)
	}
	return out
}

func unameArch(goarch string) string {
	switch goarch {
	case "amd64":
		return "x86_64"
	case "arm64":
		return "aarch64"
	case "386":
		return "i686"
	}
	return goarch
}

// Cached wraps a Collector with a TTL — inventory is near-static, so the
// overview endpoint must not re-walk sysfs on every poll tick.
type Cached struct {
	collector *Collector
	ttl       time.Duration

	mu        sync.Mutex
	inv       *Inventory
	fetchedAt time.Time
}

// NewCached returns a caching wrapper; ttl <= 0 defaults to one hour.
func NewCached(c *Collector, ttl time.Duration) *Cached {
	if ttl <= 0 {
		ttl = time.Hour
	}
	return &Cached{collector: c, ttl: ttl}
}

// Get returns the cached inventory, refreshing it when stale.
func (c *Cached) Get() *Inventory {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.inv == nil || time.Since(c.fetchedAt) > c.ttl {
		c.inv = c.collector.Collect()
		c.fetchedAt = time.Now()
	}
	return c.inv
}
