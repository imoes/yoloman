// Package kernelcaps answers "what can this kernel be tuned with?" — the
// facts the kernel-tuning loop (docs/kernel-tuning.md) has to know before it
// may propose anything: BTF, sched_ext (and which BPF scheduler is loaded),
// the relevant CONFIG_* flags, the boot loader (where a kernel command line
// is persisted) and the init system (how a tunable is made boot-persistent).
//
// Every answer is a named state, never an absent field: "unknown" means the
// source could not be read and says which, "unsupported" says why. A tuning
// proposal that rests on a capability must be able to cite the reason it is
// (or is not) available, so each verdict carries its evidence path.
//
// All roots are injectable (the test-seam pattern of internal/inventory),
// and nothing here executes a binary — only files are read.
package kernelcaps

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// Caps is the whole capability document.
type Caps struct {
	Release  string    `json:"release"` // /proc/sys/kernel/osrelease, "" only if unreadable
	BTF      Verdict   `json:"btf"`
	Config   Config    `json:"config"`
	SchedExt SchedExt  `json:"sched_ext"`
	Boot     Verdict   `json:"boot_loader"`
	Init     Verdict   `json:"init_system"`
	EBPF     Collector `json:"ebpf_collector"`
}

// Map returns the document as plain maps, the shape runbook `when:` clauses
// and templates index into (yoloman_kernel_caps.sched_ext.state).
func (c Caps) Map() map[string]any {
	b, _ := json.Marshal(c)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	return m
}

// Verdict is one classified fact plus the file that proved it.
type Verdict struct {
	State    string `json:"state"`
	Evidence string `json:"evidence,omitempty"` // path read, or why nothing could be read
}

// Config is the subset of the kernel build configuration that decides which
// tuning surfaces exist. Source is the file it came from, or "unknown".
type Config struct {
	Source string            `json:"source"`
	Flags  map[string]string `json:"flags,omitempty"` // y | m | n — n also for "absent from a readable config"
}

// SchedExt describes the extensible scheduler class (Linux >= 6.12).
type SchedExt struct {
	// State is one of: unsupported | disabled | enabling | enabled | disabling | unknown.
	State string `json:"state"`
	// Ops is the loaded BPF scheduler's name (e.g. "bpfland") when enabled.
	Ops string `json:"ops,omitempty"`
	// Reason says why sched_ext is unsupported or unknown.
	Reason string `json:"reason,omitempty"`
}

// Collector is the load result of the agent's own eBPF collector.
type Collector struct {
	// State is one of: loaded | failed | disabled | not_started.
	State  string `json:"state"`
	Reason string `json:"reason,omitempty"`
}

// ConfigFlags are the build options the tuning loop cares about.
var ConfigFlags = []string{
	"CONFIG_SCHED_CLASS_EXT", // sched_ext BPF schedulers
	"CONFIG_DEBUG_INFO_BTF",  // /sys/kernel/btf/vmlinux, needed by CO-RE BPF (scx_*)
	"CONFIG_BPF_SYSCALL",
	"CONFIG_BPF_JIT",
	"CONFIG_BPF_EVENTS", // tracepoint/kprobe BPF programs
	"CONFIG_CGROUP_BPF",
	"CONFIG_PSI", // pressure stall information
}

// Detector reads the capabilities from injectable roots.
type Detector struct {
	ProcRoot string // default /proc
	SysRoot  string // default /sys
	BootRoot string // default /boot
	RunRoot  string // default /run
}

// Default reads the real host.
func Default() *Detector {
	return &Detector{ProcRoot: "/proc", SysRoot: "/sys", BootRoot: "/boot", RunRoot: "/run"}
}

// Detect gathers every capability. It never fails: an unreadable source
// becomes a named "unknown" state that cites the path.
func (d *Detector) Detect() Caps {
	c := Caps{Release: readTrimmed(filepath.Join(d.ProcRoot, "sys/kernel/osrelease"))}
	c.BTF = d.btf()
	c.Config = d.config(c.Release)
	c.SchedExt = d.schedExt(c.Config)
	c.Boot = d.bootLoader()
	c.Init = d.initSystem()
	c.EBPF = CollectorStatus()
	return c
}

func (d *Detector) btf() Verdict {
	p := filepath.Join(d.SysRoot, "kernel/btf/vmlinux")
	if _, err := os.Stat(p); err == nil {
		return Verdict{State: "present", Evidence: p}
	} else if os.IsNotExist(err) {
		return Verdict{State: "absent", Evidence: p}
	} else {
		return Verdict{State: "unknown", Evidence: p + ": " + err.Error()}
	}
}

// config reads /proc/config.gz first (the running kernel's own view), then
// /boot/config-<release> (what the distribution ships next to the image).
func (d *Detector) config(release string) Config {
	candidates := []string{filepath.Join(d.ProcRoot, "config.gz")}
	if release != "" {
		candidates = append(candidates, filepath.Join(d.BootRoot, "config-"+release))
	}
	for _, p := range candidates {
		flags, err := readConfig(p)
		if err == nil {
			return Config{Source: p, Flags: flags}
		}
	}
	return Config{Source: "unknown"}
}

func readConfig(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var r io.Reader = f
	if strings.HasSuffix(path, ".gz") {
		gz, err := gzip.NewReader(f)
		if err != nil {
			return nil, err
		}
		defer gz.Close()
		r = gz
	}
	want := make(map[string]bool, len(ConfigFlags))
	flags := make(map[string]string, len(ConfigFlags))
	for _, k := range ConfigFlags {
		want[k] = true
		flags[k] = "n" // absent from a readable config means "not built"
	}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if k, v, ok := strings.Cut(line, "="); ok && want[k] {
			flags[k] = strings.Trim(v, `"`)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return flags, nil
}

// schedExt reads /sys/kernel/sched_ext/state; root/ops exists only while a
// BPF scheduler is attached. When the directory is missing the reason is
// derived from the kernel config if it was readable.
func (d *Detector) schedExt(cfg Config) SchedExt {
	dir := filepath.Join(d.SysRoot, "kernel/sched_ext")
	state, err := readFirst(filepath.Join(dir, "state"))
	if err != nil {
		if !os.IsNotExist(err) {
			return SchedExt{State: "unknown", Reason: err.Error()}
		}
		switch cfg.Flags["CONFIG_SCHED_CLASS_EXT"] {
		case "":
			return SchedExt{State: "unsupported", Reason: dir + " missing (kernel < 6.12 or built without CONFIG_SCHED_CLASS_EXT; config unreadable)"}
		case "y":
			return SchedExt{State: "unknown", Reason: "CONFIG_SCHED_CLASS_EXT=y but " + dir + " missing (sysfs not mounted?)"}
		default:
			return SchedExt{State: "unsupported", Reason: "CONFIG_SCHED_CLASS_EXT=" + cfg.Flags["CONFIG_SCHED_CLASS_EXT"] + " in " + cfg.Source}
		}
	}
	s := SchedExt{State: state}
	switch state {
	case "disabled", "enabling", "enabled", "disabling":
	default:
		return SchedExt{State: "unknown", Reason: "unrecognised sched_ext state " + `"` + state + `"`}
	}
	if ops, err := readFirst(filepath.Join(dir, "root/ops")); err == nil {
		s.Ops = ops
	}
	return s
}

// bootLoader decides where a kernel command line is persisted. systemd's
// EFI variables are the strongest proof (the loader wrote them at this
// boot); config files only show what is installed.
func (d *Detector) bootLoader() Verdict {
	const loaderVendor = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
	efivars := filepath.Join(d.SysRoot, "firmware/efi/efivars")
	checks := []struct{ state, path string }{
		{"uki", filepath.Join(efivars, "StubInfo-"+loaderVendor)},
		{"systemd-boot", filepath.Join(efivars, "LoaderInfo-"+loaderVendor)},
		{"grub", filepath.Join(d.BootRoot, "grub/grub.cfg")},
		{"grub", filepath.Join(d.BootRoot, "grub2/grub.cfg")},
		{"extlinux", filepath.Join(d.BootRoot, "extlinux/extlinux.conf")},
	}
	for _, c := range checks {
		if _, err := os.Stat(c.path); err == nil {
			return Verdict{State: c.state, Evidence: c.path}
		}
	}
	return Verdict{State: "unknown", Evidence: "none of the loader markers under " + efivars + " or " + d.BootRoot + " exist"}
}

// initSystem tells the tuning modules how to make a value boot-persistent
// (systemd drop-ins/tmpfiles.d vs OpenRC conf.d/local.d).
func (d *Detector) initSystem() Verdict {
	for _, c := range []struct{ state, path string }{
		{"systemd", filepath.Join(d.RunRoot, "systemd/system")},
		{"openrc", filepath.Join(d.RunRoot, "openrc")},
	} {
		if _, err := os.Stat(c.path); err == nil {
			return Verdict{State: c.state, Evidence: c.path}
		}
	}
	return Verdict{State: "unknown", Evidence: "neither " + filepath.Join(d.RunRoot, "systemd/system") + " nor " + filepath.Join(d.RunRoot, "openrc") + " exists"}
}

var (
	collectorMu     sync.Mutex
	collectorStatus = Collector{State: "not_started"}
)

// SetCollectorStatus records the eBPF collector's load result; the daemon
// calls it once at startup (cmd/agentic-mcpd startEBPFCollector).
func SetCollectorStatus(state, reason string) {
	collectorMu.Lock()
	defer collectorMu.Unlock()
	collectorStatus = Collector{State: state, Reason: reason}
}

// CollectorStatus returns the recorded eBPF collector load result.
func CollectorStatus() Collector {
	collectorMu.Lock()
	defer collectorMu.Unlock()
	return collectorStatus
}

func readFirst(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return strings.TrimSpace(line), nil
}

func readTrimmed(path string) string {
	s, _ := readFirst(path)
	return s
}
