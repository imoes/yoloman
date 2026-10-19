package embedded

import (
	"fmt"
	"io/fs"
	"path"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/starmod"
)

// fakeHost is an in-memory host for the kernel-tuning modules
// (docs/kernel-tuning.md): files are a map, commands are answered by a
// handler, and every mutating command is recorded. It lets the modules'
// real logic run — before/after, idempotency, check mode — without
// touching the machine the tests run on.
type fakeHost struct {
	check    bool
	files    map[string]string
	facts    map[string]any
	handle   func(h *fakeHost, argv []string) (starmod.RunResult, bool)
	mutating [][]string
}

func newFakeHost(init string) *fakeHost {
	return &fakeHost{
		files: map[string]string{},
		facts: map[string]any{
			"os_family": "debian",
			"kernel_caps": map[string]any{
				"init_system": map[string]any{"state": init},
				"boot_loader": map[string]any{"state": "grub", "evidence": "/boot/grub/grub.cfg"},
				"btf":         map[string]any{"state": "present"},
				"sched_ext":   map[string]any{"state": "disabled"},
			},
		},
	}
}

func (h *fakeHost) CheckMode() bool { return h.check }

func (h *fakeHost) Run(argv []string, mutates bool, _ []int) (starmod.RunResult, error) {
	if mutates {
		if h.check {
			return starmod.RunResult{Skipped: true}, nil
		}
		h.mutating = append(h.mutating, argv)
	}
	if h.handle != nil {
		if r, ok := h.handle(h, argv); ok {
			return r, nil
		}
	}
	switch {
	case argv[0] == "ls" && len(argv) == 2:
		return starmod.RunResult{Stdout: strings.Join(h.children(argv[1]), "\n")}, nil
	case argv[0] == "rm":
		for _, a := range argv[1:] {
			if !strings.HasPrefix(a, "-") {
				delete(h.files, a)
			}
		}
		return starmod.RunResult{}, nil
	case argv[0] == "sh" && len(argv) > 4 && strings.Contains(argv[2], `printf "%s" "$v"`):
		// _WRITE: sh -c SCRIPT sh VALUE PATH...
		for _, p := range argv[5:] {
			h.files[p] = argv[4]
		}
		return starmod.RunResult{}, nil
	}
	return starmod.RunResult{RC: 127, Stderr: "fakeHost: unhandled " + strings.Join(argv, " ")}, nil
}

func (h *fakeHost) children(dir string) []string {
	seen := map[string]bool{}
	for p := range h.files {
		if rest, ok := strings.CutPrefix(p, dir+"/"); ok {
			seen[strings.SplitN(rest, "/", 2)[0]] = true
		}
	}
	out := make([]string, 0, len(seen))
	for n := range seen {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

func (h *fakeHost) FileRead(p string) (string, error) {
	if v, ok := h.files[p]; ok {
		return v, nil
	}
	return "", fs.ErrNotExist
}

func (h *fakeHost) FileWrite(p, content, _ string) (bool, error) {
	if h.files[p] == content {
		return false, nil
	}
	if !h.check {
		h.files[p] = content
	}
	return true, nil
}

func (h *fakeHost) FileExists(p string) (bool, error) {
	if _, ok := h.files[p]; ok {
		return true, nil
	}
	return len(h.children(p)) > 0, nil
}

func (h *fakeHost) Stat(p string) (map[string]any, error) {
	if ok, _ := h.FileExists(p); !ok {
		return nil, nil
	}
	return map[string]any{"exists": true}, nil
}

func (h *fakeHost) Facts() (map[string]any, error) { return h.facts, nil }

func (h *fakeHost) Probe(string, map[string]any) (map[string]any, error) { return nil, nil }

// runModule executes one baked yoloman module against the fake host.
func runModule(t *testing.T, name string, h *fakeHost, params map[string]any) (starmod.Result, error) {
	t.Helper()
	fsys, err := FS()
	if err != nil {
		t.Fatal(err)
	}
	src, err := fs.ReadFile(fsys, path.Join("yoloman", name+".star"))
	if err != nil {
		t.Fatal(err)
	}
	return starmod.Execute(name+".star", src, params, h, starmod.Options{})
}

func dataOf(t *testing.T, r starmod.Result) map[string]any {
	t.Helper()
	d, ok := r.Data.(map[string]any)
	if !ok {
		t.Fatalf("result data is %T, want a dict", r.Data)
	}
	return d
}

func cpufreqHost(init string, govs ...string) *fakeHost {
	h := newFakeHost(init)
	for i, g := range govs {
		base := "/sys/devices/system/cpu/cpu" + string(rune('0'+i)) + "/cpufreq/"
		h.files[base+"scaling_governor"] = g + "\n"
		h.files[base+"scaling_available_governors"] = "performance powersave schedutil\n"
	}
	h.files["/sys/devices/system/cpu/online"] = "0-1\n"
	return h
}

func TestCPUGovernorSetsAllCPUsAndPersists(t *testing.T) {
	h := cpufreqHost("systemd", "powersave", "schedutil")
	r, err := runModule(t, "cpu_governor", h, map[string]any{"governor": "performance"})
	if err != nil {
		t.Fatal(err)
	}
	if !r.Changed {
		t.Error("changed = false, want true")
	}
	for _, c := range []string{"cpu0", "cpu1"} {
		if got := h.files["/sys/devices/system/cpu/"+c+"/cpufreq/scaling_governor"]; got != "performance" {
			t.Errorf("%s governor = %q", c, got)
		}
	}
	if !strings.Contains(h.files["/etc/tmpfiles.d/yoloman-cpufreq.conf"], "w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance") {
		t.Errorf("tmpfiles.d = %q", h.files["/etc/tmpfiles.d/yoloman-cpufreq.conf"])
	}
	d := dataOf(t, r)
	if d["persistence"] != "persistent" {
		t.Errorf("persistence = %v", d["persistence"])
	}
	// Two different values before → no single rollback value (named by its absence of "governor").
	if _, ok := d["rollback"].(map[string]any)["governor"]; ok {
		t.Errorf("rollback has a governor although the CPUs disagreed: %v", d["rollback"])
	}

	// Second run: idempotent.
	r, err = runModule(t, "cpu_governor", h, map[string]any{"governor": "performance"})
	if err != nil || r.Changed {
		t.Errorf("second run changed=%v err=%v, want unchanged", r.Changed, err)
	}
}

func TestCPUGovernorCheckModeTouchesNothing(t *testing.T) {
	h := cpufreqHost("systemd", "powersave")
	h.check = true
	r, err := runModule(t, "cpu_governor", h, map[string]any{"governor": "performance"})
	if err != nil || !r.Changed {
		t.Fatalf("changed=%v err=%v, want predicted change", r.Changed, err)
	}
	if h.files["/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"] != "powersave\n" || len(h.mutating) != 0 {
		t.Errorf("check mode mutated: %v", h.mutating)
	}
	if _, ok := h.files["/etc/tmpfiles.d/yoloman-cpufreq.conf"]; ok {
		t.Error("check mode wrote the tmpfiles.d file")
	}
	rb := dataOf(t, r)["rollback"].(map[string]any)
	if rb["governor"] != "powersave" {
		t.Errorf("rollback = %v", rb)
	}
}

func TestCPUGovernorOpenRCAndRefusals(t *testing.T) {
	h := cpufreqHost("openrc", "powersave")
	if _, err := runModule(t, "cpu_governor", h, map[string]any{"governor": "performance"}); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h.files["/etc/local.d/yoloman-cpufreq.start"], "#!/bin/sh") {
		t.Errorf("local.d script = %q", h.files["/etc/local.d/yoloman-cpufreq.start"])
	}
	// A governor the driver does not offer is refused with the offered list.
	if _, err := runModule(t, "cpu_governor", h, map[string]any{"governor": "ondemand"}); err == nil || !strings.Contains(err.Error(), "unsupported: scaling_governor=ondemand") {
		t.Errorf("err = %v", err)
	}
	// No cpufreq at all (a VM).
	if _, err := runModule(t, "cpu_governor", newFakeHost("systemd"), map[string]any{"governor": "performance"}); err == nil || !strings.Contains(err.Error(), "unsupported: no cpufreq driver") {
		t.Errorf("err = %v", err)
	}
	// Unknown init system: live only works, persistent is refused.
	u := cpufreqHost("unknown", "powersave")
	if _, err := runModule(t, "cpu_governor", u, map[string]any{"governor": "performance"}); err == nil || !strings.Contains(err.Error(), "unsupported: no persistence path") {
		t.Errorf("err = %v", err)
	}
	if len(u.mutating) != 0 || u.files["/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"] != "powersave\n" {
		t.Errorf("a refused run changed the live value: %v", u.mutating)
	}
	if r, err := runModule(t, "cpu_governor", u, map[string]any{"governor": "performance", "persistent": false}); err != nil || dataOf(t, r)["persistence"] != "live" {
		t.Errorf("live-only: err=%v", err)
	}
}

func blockHost(udevProps string) *fakeHost {
	h := newFakeHost("systemd")
	h.files["/sys/block/sdb/queue/read_ahead_kb"] = "128\n"
	h.files["/sys/block/sdb/queue/scheduler"] = "[none] mq-deadline kyber bfq\n"
	h.handle = func(h *fakeHost, argv []string) (starmod.RunResult, bool) {
		switch {
		case len(argv) == 3 && argv[0] == "sh" && argv[2] == "command -v udevadm":
			return starmod.RunResult{Stdout: "/usr/bin/udevadm\n"}, true
		case argv[0] == "udevadm":
			return starmod.RunResult{Stdout: udevProps}, true
		}
		return starmod.RunResult{}, false
	}
	return h
}

func TestBlockdevTuningLiveAndUdevRule(t *testing.T) {
	h := blockHost("DEVTYPE=disk\nID_SERIAL=QEMU_HARDDISK_drive-scsi1\nID_WWN=0x5000c500a1b2c3d4\n")
	r, err := runModule(t, "blockdev_tuning", h, map[string]any{"device": "/dev/sdb", "read_ahead_kb": 4096, "scheduler": "mq-deadline"})
	if err != nil {
		t.Fatal(err)
	}
	if !r.Changed || h.files["/sys/block/sdb/queue/read_ahead_kb"] != "4096" || h.files["/sys/block/sdb/queue/scheduler"] != "mq-deadline" {
		t.Errorf("changed=%v files=%v", r.Changed, h.files)
	}
	rule := h.files["/etc/udev/rules.d/60-yoloman-blockdev-sdb.rules"]
	if !strings.Contains(rule, `ENV{ID_WWN}=="0x5000c500a1b2c3d4"`) || !strings.Contains(rule, `ATTR{queue/read_ahead_kb}="4096"`) {
		t.Errorf("rule = %q", rule)
	}
	d := dataOf(t, r)
	rb := d["rollback"].(map[string]any)
	if rb["read_ahead_kb"] != int64(128) && rb["read_ahead_kb"] != 128 {
		t.Errorf("rollback = %v", rb)
	}
	if rb["scheduler"] != "none" || d["match_stable"] != true {
		t.Errorf("rollback=%v match_stable=%v", rb, d["match_stable"])
	}
	// The scheduler file now reads "mq-deadline" without brackets in the fake; the real
	// kernel brackets it — make the fake match before the idempotency run.
	h.files["/sys/block/sdb/queue/scheduler"] = "none [mq-deadline] kyber bfq\n"
	if r, err := runModule(t, "blockdev_tuning", h, map[string]any{"device": "sdb", "read_ahead_kb": 4096, "scheduler": "mq-deadline"}); err != nil || r.Changed {
		t.Errorf("second run changed=%v err=%v", r.Changed, err)
	}
}

func TestBlockdevTuningUnstableNameAndRefusals(t *testing.T) {
	h := blockHost("DEVTYPE=disk\n")
	r, err := runModule(t, "blockdev_tuning", h, map[string]any{"device": "sdb", "read_ahead_kb": 256})
	if err != nil {
		t.Fatal(err)
	}
	if d := dataOf(t, r); d["match_stable"] != false || !strings.Contains(d["match"].(string), `KERNEL=="sdb"`) {
		t.Errorf("match=%v stable=%v", d["match"], d["match_stable"])
	}
	for _, c := range []struct {
		params map[string]any
		want   string
	}{
		{map[string]any{"device": "sdb", "scheduler": "cfq"}, "unsupported: scheduler cfq not offered"},
		{map[string]any{"device": "sdz", "read_ahead_kb": 1}, "unsupported: /sys/block/sdz/queue missing"},
		{map[string]any{"device": "sdb;rm", "read_ahead_kb": 1}, "device must be a kernel block device name"},
		{map[string]any{"device": "sdb", "read_ahead_kb": 70000}, "within 0..65536"},
	} {
		if _, err := runModule(t, "blockdev_tuning", h, c.params); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%v: err = %v, want %q", c.params, err, c.want)
		}
	}
}

// systemdHost fakes `systemctl show/set-property/daemon-reload` for one unit,
// reporting values the way systemd does (bytes, CPUQuotaPerSecUSec).
func systemdHost() (*fakeHost, map[string]string) {
	props := map[string]string{
		"LoadState": "loaded", "CPUWeight": "[not set]", "MemoryHigh": "infinity",
		"CPUQuotaPerSecUSec": "infinity", "TasksMax": "4915",
	}
	h := newFakeHost("systemd")
	h.handle = func(h *fakeHost, argv []string) (starmod.RunResult, bool) {
		if argv[0] != "systemctl" {
			return starmod.RunResult{}, false
		}
		switch argv[1] {
		case "show":
			var lines []string
			for _, k := range strings.Split(argv[3], ",") {
				lines = append(lines, k+"="+props[k])
			}
			return starmod.RunResult{Stdout: strings.Join(lines, "\n") + "\n"}, true
		case "set-property":
			for _, kv := range argv[4:] {
				k, v, _ := strings.Cut(kv, "=")
				switch {
				case k == "MemoryHigh" && v == "6G":
					v = "6442450944"
				case k == "CPUQuota" && v == "50%":
					k, v = "CPUQuotaPerSecUSec", "500ms"
				case k == "CPUQuota" && v == "150%":
					k, v = "CPUQuotaPerSecUSec", "1.500000s"
				}
				if v == "" && k == "CPUWeight" {
					v = "[not set]" // systemd: an empty assignment resets to the default
				}
				props[k] = v
			}
			return starmod.RunResult{}, true
		case "daemon-reload":
			return starmod.RunResult{}, true
		}
		return starmod.RunResult{}, false
	}
	inner := h.handle
	h.handle = func(h *fakeHost, argv []string) (starmod.RunResult, bool) {
		if argv[0] == "mkdir" || argv[0] == "rmdir" {
			return starmod.RunResult{}, true
		}
		return inner(h, argv)
	}
	return h, props
}

func TestSystemdResourceNormalisesAndIsIdempotent(t *testing.T) {
	h, props := systemdHost()
	p := map[string]any{"unit": "postgresql", "properties": map[string]any{"CPUWeight": 400, "MemoryHigh": "6G", "CPUQuota": "150%"}}
	r, err := runModule(t, "systemd_resource", h, p)
	if err != nil {
		t.Fatal(err)
	}
	if !r.Changed || props["CPUWeight"] != "400" || props["MemoryHigh"] != "6442450944" || props["CPUQuotaPerSecUSec"] != "1.500000s" {
		t.Errorf("changed=%v props=%v", r.Changed, props)
	}
	dropin := h.files["/etc/systemd/system/postgresql.service.d/90-yoloman-resource.conf"]
	if !strings.Contains(dropin, "[Service]\nCPUQuota=150%\nCPUWeight=400\nMemoryHigh=6G\n") {
		t.Errorf("drop-in = %q", dropin)
	}
	rb := dataOf(t, r)["rollback"].(map[string]any)["properties"].(map[string]any)
	if rb["CPUWeight"] != "" || rb["MemoryHigh"] != "infinity" || rb["CPUQuota"] != "" {
		t.Errorf("rollback = %v", rb)
	}
	// 6G vs 6442450944 and 150% vs 1.500000s compare equal: unchanged.
	h.mutating = nil
	if r, err := runModule(t, "systemd_resource", h, p); err != nil || r.Changed || len(h.mutating) != 0 {
		t.Errorf("second run changed=%v err=%v mutating=%v", r.Changed, err, h.mutating)
	}
}

func TestSystemdResourceRefusals(t *testing.T) {
	h, props := systemdHost()
	for _, c := range []struct {
		params map[string]any
		want   string
	}{
		{map[string]any{"unit": "x.service", "properties": map[string]any{"Nice": 5}}, "property Nice not supported"},
		{map[string]any{"unit": "x;rm -rf", "properties": map[string]any{"CPUWeight": 5}}, "unit must be a systemd unit name"},
		{map[string]any{"unit": "run-1.scope", "properties": map[string]any{"CPUWeight": 5}}, "unsupported: a .scope unit cannot carry a persistent drop-in"},
		{map[string]any{"unit": "x.service", "properties": map[string]any{"MemoryMax": "1G 2G"}}, "invalid value"},
	} {
		if _, err := runModule(t, "systemd_resource", h, c.params); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%v: err = %v, want %q", c.params, err, c.want)
		}
	}
	props["LoadState"] = "not-found"
	if _, err := runModule(t, "systemd_resource", h, map[string]any{"unit": "nope", "properties": map[string]any{"CPUWeight": 5}}); err == nil || !strings.Contains(err.Error(), "is not loaded (LoadState=not-found)") {
		t.Errorf("err = %v", err)
	}
	o := newFakeHost("openrc")
	if _, err := runModule(t, "systemd_resource", o, map[string]any{"unit": "x", "properties": map[string]any{"CPUWeight": 5}}); err == nil || !strings.Contains(err.Error(), "unsupported: systemd_resource needs systemd") {
		t.Errorf("err = %v", err)
	}
}

// schedHost fakes a sched_ext kernel plus systemd: starting the unit makes the
// kernel report "enabled" with the scheduler's ops name, unless attach=false.
func schedHost(attach bool) (*fakeHost, *bool) {
	active := false
	enabled := false
	h := newFakeHost("systemd")
	h.files["/sys/kernel/sched_ext/state"] = "disabled\n"
	h.handle = func(h *fakeHost, argv []string) (starmod.RunResult, bool) {
		switch {
		case argv[0] == "sh" && strings.Contains(argv[2], "command -v"):
			if argv[4] == "bpfland" {
				return starmod.RunResult{Stdout: "/usr/bin/scx_bpfland\n"}, true
			}
			return starmod.RunResult{RC: 1}, true
		case argv[0] == "systemctl" && argv[1] == "is-active":
			return starmod.RunResult{RC: map[bool]int{true: 0, false: 3}[active]}, true
		case argv[0] == "systemctl" && argv[1] == "is-enabled":
			return starmod.RunResult{RC: map[bool]int{true: 0, false: 1}[enabled]}, true
		case argv[0] == "systemctl" && (argv[1] == "enable" || argv[1] == "disable"):
			enabled = argv[1] == "enable"
			return starmod.RunResult{}, true
		case argv[0] == "systemctl" && argv[1] == "daemon-reload":
			return starmod.RunResult{}, true
		case argv[0] == "systemctl" && argv[1] == "restart":
			active = true
			if attach {
				h.files["/sys/kernel/sched_ext/state"] = "enabled\n"
				h.files["/sys/kernel/sched_ext/root/ops"] = "bpfland_1.0.14_x86_64\n"
			}
			return starmod.RunResult{}, true
		case argv[0] == "systemctl" && argv[1] == "stop":
			active = false
			h.files["/sys/kernel/sched_ext/state"] = "disabled\n"
			delete(h.files, "/sys/kernel/sched_ext/root/ops")
			return starmod.RunResult{}, true
		case argv[0] == "timeout":
			want := argv[len(argv)-1]
			if strings.TrimSpace(h.files["/sys/kernel/sched_ext/state"]) == want {
				return starmod.RunResult{}, true
			}
			return starmod.RunResult{RC: 124}, true
		case argv[0] == "journalctl":
			return starmod.RunResult{Stdout: "EXIT: scx_bpfland: failed to attach\n"}, true
		}
		return starmod.RunResult{}, false
	}
	return h, &enabled
}

func TestSchedExtStartStopRollback(t *testing.T) {
	h, enabled := schedHost(true)
	r, err := runModule(t, "sched_ext", h, map[string]any{"scheduler": "bpfland", "args": []any{"--slice-us", "5000"}})
	if err != nil {
		t.Fatal(err)
	}
	d := dataOf(t, r)
	after := d["after"].(map[string]any)
	if !r.Changed || after["state"] != "enabled" || after["ops"] != "bpfland_1.0.14_x86_64" || !*enabled {
		t.Errorf("changed=%v after=%v enabled=%v", r.Changed, after, *enabled)
	}
	if !strings.Contains(h.files["/etc/systemd/system/yoloman-sched-ext.service"], "ExecStart=/usr/bin/scx_bpfland --slice-us 5000\n") {
		t.Errorf("unit = %q", h.files["/etc/systemd/system/yoloman-sched-ext.service"])
	}
	if rb := d["rollback"].(map[string]any); rb["state"] != "disabled" {
		t.Errorf("rollback after first start = %v", rb)
	}
	// Idempotent while attached.
	if r, err := runModule(t, "sched_ext", h, map[string]any{"scheduler": "bpfland", "args": []any{"--slice-us", "5000"}}); err != nil || r.Changed {
		t.Errorf("second run changed=%v err=%v", r.Changed, err)
	}
	// Disable: back to the fair class; the rollback re-enables what ran.
	r, err = runModule(t, "sched_ext", h, map[string]any{"state": "disabled"})
	if err != nil {
		t.Fatal(err)
	}
	d = dataOf(t, r)
	if d["after"].(map[string]any)["state"] != "disabled" || *enabled {
		t.Errorf("after=%v enabled=%v", d["after"], *enabled)
	}
	rb := d["rollback"].(map[string]any)
	if rb["state"] != "enabled" || rb["scheduler"] != "bpfland" {
		t.Errorf("rollback = %v", rb)
	}
}

func TestSchedExtFailedAttachIsUndone(t *testing.T) {
	h, enabled := schedHost(false)
	_, err := runModule(t, "sched_ext", h, map[string]any{"scheduler": "bpfland", "wait": 1})
	if err == nil || !strings.Contains(err.Error(), "did not attach") || !strings.Contains(err.Error(), "failed to attach") {
		t.Fatalf("err = %v", err)
	}
	if *enabled {
		t.Error("a scheduler that never attached was left enabled at boot")
	}
}

func TestSchedExtRefusals(t *testing.T) {
	h, _ := schedHost(true)
	if _, err := runModule(t, "sched_ext", h, map[string]any{"scheduler": "lavd"}); err == nil || !strings.Contains(err.Error(), "tool_unavailable: scx_lavd") {
		t.Errorf("err = %v", err)
	}
	if _, err := runModule(t, "sched_ext", h, map[string]any{"scheduler": "bpfland", "args": []any{"$(reboot)"}}); err == nil || !strings.Contains(err.Error(), "characters outside") {
		t.Errorf("err = %v", err)
	}
	// A scheduler yoloman did not start is a conflict, in both directions.
	h.files["/sys/kernel/sched_ext/state"] = "enabled\n"
	h.files["/sys/kernel/sched_ext/root/ops"] = "rusty\n"
	for _, p := range []map[string]any{{"scheduler": "bpfland"}, {"state": "disabled"}} {
		if _, err := runModule(t, "sched_ext", h, p); err == nil || !strings.Contains(err.Error(), "conflict:") {
			t.Errorf("%v: err = %v", p, err)
		}
	}
	u := newFakeHost("systemd")
	u.facts["kernel_caps"].(map[string]any)["sched_ext"] = map[string]any{"state": "unsupported", "reason": "CONFIG_SCHED_CLASS_EXT=n in /boot/config-6.1"}
	if _, err := runModule(t, "sched_ext", u, map[string]any{"scheduler": "bpfland"}); err == nil || !strings.Contains(err.Error(), "unsupported: sched_ext is unsupported (CONFIG_SCHED_CLASS_EXT=n") {
		t.Errorf("err = %v", err)
	}
}

func cmdlineHost(tools ...string) *fakeHost {
	h := newFakeHost("systemd")
	h.files["/proc/cmdline"] = "BOOT_IMAGE=/vmlinuz root=/dev/sda1 ro quiet splash\n"
	have := map[string]bool{}
	for _, t := range tools {
		have[t] = true
	}
	h.handle = func(h *fakeHost, argv []string) (starmod.RunResult, bool) {
		if argv[0] == "sh" && len(argv) == 3 && strings.HasPrefix(argv[2], "command -v ") {
			if have[strings.TrimPrefix(argv[2], "command -v ")] {
				return starmod.RunResult{Stdout: "/usr/sbin/x\n"}, true
			}
			return starmod.RunResult{RC: 1}, true
		}
		switch argv[0] {
		case "update-grub", "grub2-mkconfig", "grub-mkconfig", "update-extlinux":
			return starmod.RunResult{}, true
		case "grubby":
			if argv[1] == "--info=DEFAULT" {
				return starmod.RunResult{Stdout: "index=0\nkernel=\"/boot/vmlinuz-6.12\"\nargs=\"ro crashkernel=1G-4G:192M rhgb quiet\"\n"}, true
			}
			return starmod.RunResult{}, true
		}
		return starmod.RunResult{}, false
	}
	return h
}

func TestKernelCmdlineGrubDebianEditsTheEffectiveFile(t *testing.T) {
	h := cmdlineHost("update-grub")
	h.files["/etc/default/grub"] = "GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"\nGRUB_CMDLINE_LINUX=\"\"\n"
	// A cloud-image style override that grub-mkconfig sources after /etc/default/grub.
	h.files["/etc/default/grub.d/50-cloudimg.cfg"] = "GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0 quiet\"\n"
	r, err := runModule(t, "kernel_cmdline", h, map[string]any{"add": []any{"mitigations=off"}, "remove": []any{"quiet"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := h.files["/etc/default/grub.d/50-cloudimg.cfg"]; got != "GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0\"\n" {
		t.Errorf("override file = %q (quiet must be removed where it is really defined)", got)
	}
	if !strings.Contains(h.files["/etc/default/grub"], "GRUB_CMDLINE_LINUX=\"mitigations=off\"\n") ||
		!strings.Contains(h.files["/etc/default/grub"], "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"") {
		t.Errorf("/etc/default/grub = %q", h.files["/etc/default/grub"])
	}
	ran := false
	for _, m := range h.mutating {
		ran = ran || m[0] == "update-grub"
	}
	if !ran {
		t.Errorf("update-grub not run: %v", h.mutating)
	}
	d := dataOf(t, r)
	if d["persistence"] != "pending_reboot" {
		t.Errorf("persistence = %v", d["persistence"])
	}
	rb := d["rollback"].(map[string]any)
	if strings.Join(toStrings(rb["add"]), " ") != "quiet" || strings.Join(toStrings(rb["remove"]), " ") != "mitigations" {
		t.Errorf("rollback = %v", rb)
	}
	h.mutating = nil
	if r, err := runModule(t, "kernel_cmdline", h, map[string]any{"add": []any{"mitigations=off"}, "remove": []any{"quiet"}}); err != nil || r.Changed || len(h.mutating) != 0 {
		t.Errorf("second run changed=%v err=%v mutating=%v", r.Changed, err, h.mutating)
	}
}

func toStrings(v any) []string {
	var out []string
	for _, x := range v.([]any) {
		out = append(out, x.(string))
	}
	return out
}

func TestKernelCmdlineGrubbyAndExtlinux(t *testing.T) {
	h := cmdlineHost("grubby")
	r, err := runModule(t, "kernel_cmdline", h, map[string]any{"add": []any{"crashkernel=auto"}, "remove": []any{"rhgb"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(h.mutating) != 1 || strings.Join(h.mutating[0], " ") != "grubby --update-kernel=ALL --args=crashkernel=auto --remove-args=rhgb" {
		t.Errorf("mutating = %v", h.mutating)
	}
	rb := dataOf(t, r)["rollback"].(map[string]any)
	if strings.Join(toStrings(rb["add"]), " ") != "rhgb crashkernel=1G-4G:192M" {
		t.Errorf("rollback = %v", rb)
	}

	a := cmdlineHost("update-extlinux")
	a.facts["kernel_caps"].(map[string]any)["boot_loader"] = map[string]any{"state": "extlinux", "evidence": "/boot/extlinux/extlinux.conf"}
	a.files["/etc/update-extlinux.conf"] = "overwrite=1\ndefault_kernel_opts=\"quiet rootfstype=ext4\"\n"
	if _, err := runModule(t, "kernel_cmdline", a, map[string]any{"add": []any{"nosmt"}}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(a.files["/etc/update-extlinux.conf"], "default_kernel_opts=\"quiet rootfstype=ext4 nosmt\"") {
		t.Errorf("extlinux conf = %q", a.files["/etc/update-extlinux.conf"])
	}
}

func TestKernelCmdlineRefusals(t *testing.T) {
	h := cmdlineHost("update-grub")
	h.files["/etc/default/grub"] = "GRUB_CMDLINE_LINUX=\"$EXTRA quiet\"\n"
	if _, err := runModule(t, "kernel_cmdline", h, map[string]any{"add": []any{"nosmt"}}); err == nil || !strings.Contains(err.Error(), "computed by the shell") {
		t.Errorf("err = %v", err)
	}
	if len(h.mutating) != 0 {
		t.Errorf("refusal mutated: %v", h.mutating)
	}
	if _, err := runModule(t, "kernel_cmdline", h, map[string]any{"add": []any{"a b"}}); err == nil || !strings.Contains(err.Error(), "whitespace, quotes or shell") {
		t.Errorf("err = %v", err)
	}
	s := cmdlineHost()
	s.facts["kernel_caps"].(map[string]any)["boot_loader"] = map[string]any{"state": "systemd-boot", "evidence": "/sys/firmware/efi/efivars/LoaderInfo-x"}
	if _, err := runModule(t, "kernel_cmdline", s, map[string]any{"add": []any{"nosmt"}}); err == nil || !strings.Contains(err.Error(), "unsupported: boot loader systemd-boot") {
		t.Errorf("err = %v", err)
	}
	// check mode: predicted change, no file written, no regeneration.
	c := cmdlineHost("update-grub")
	c.check = true
	c.files["/etc/default/grub"] = "GRUB_CMDLINE_LINUX=\"\"\n"
	if r, err := runModule(t, "kernel_cmdline", c, map[string]any{"add": []any{"nosmt"}}); err != nil || !r.Changed || c.files["/etc/default/grub"] != "GRUB_CMDLINE_LINUX=\"\"\n" || len(c.mutating) != 0 {
		t.Errorf("check mode: changed=%v err=%v file=%q mutating=%v", r.Changed, err, c.files["/etc/default/grub"], c.mutating)
	}
}

// The rollback a module reports must, run as one call, restore the host
// exactly — files, sysfs values and unit properties. This is what the tuning
// loop relies on when it undoes a change (docs/kernel-tuning.md, block 7).
func TestRollbackRestoresTheHostExactly(t *testing.T) {
	snapshot := func(h *fakeHost, extra map[string]string) map[string]string {
		out := map[string]string{}
		for k, v := range h.files {
			out[k] = strings.TrimSpace(strings.Trim(strings.TrimSpace(v), "[]"))
		}
		for k, v := range extra {
			out["prop:"+k] = v
		}
		return out
	}
	normSched := func(h *fakeHost) {
		// The kernel brackets the active scheduler; the fake writes it bare.
		if v := h.files["/sys/block/sdb/queue/scheduler"]; !strings.Contains(v, "[") {
			line := ""
			for _, s := range []string{"none", "mq-deadline", "kyber", "bfq"} {
				if s == strings.TrimSpace(v) {
					s = "[" + s + "]"
				}
				line += s + " "
			}
			h.files["/sys/block/sdb/queue/scheduler"] = strings.TrimSpace(line) + "\n"
		}
	}
	cases := []struct {
		name   string
		host   func() (*fakeHost, map[string]string)
		params map[string]any
		fix    func(*fakeHost)
	}{
		{"cpu_governor", func() (*fakeHost, map[string]string) { return cpufreqHost("systemd", "powersave"), nil },
			map[string]any{"governor": "performance"}, nil},
		{"blockdev_tuning", func() (*fakeHost, map[string]string) { return blockHost("ID_WWN=0x1\n"), nil },
			map[string]any{"device": "sdb", "read_ahead_kb": 4096, "scheduler": "bfq"}, normSched},
		{"systemd_resource", func() (*fakeHost, map[string]string) { return systemdHost() },
			map[string]any{"unit": "db", "properties": map[string]any{"CPUWeight": 400, "MemoryHigh": "6G"}}, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h, props := c.host()
			want := snapshot(h, props)
			r, err := runModule(t, c.name, h, c.params)
			if err != nil || !r.Changed {
				t.Fatalf("apply: changed=%v err=%v", r.Changed, err)
			}
			if c.fix != nil {
				c.fix(h)
			}
			rb := dataOf(t, r)["rollback"].(map[string]any)
			if _, err := runModule(t, c.name, h, rb); err != nil {
				t.Fatalf("rollback %v: %v", rb, err)
			}
			if c.fix != nil {
				c.fix(h)
			}
			got := snapshot(h, props)
			for k, v := range want {
				if got[k] != v {
					t.Errorf("%s: %q after rollback, want %q", k, got[k], v)
				}
			}
			for k := range got {
				if _, ok := want[k]; !ok {
					t.Errorf("%s left behind after rollback", k)
				}
			}
		})
	}
}

func benchHost(stdout, stderr string, tools ...string) *fakeHost {
	h := newFakeHost("systemd")
	h.files["/var/tmp/.keep"] = ""
	have := map[string]bool{}
	for _, t := range tools {
		have[t] = true
	}
	h.handle = func(h *fakeHost, argv []string) (starmod.RunResult, bool) {
		switch {
		case argv[0] == "sh" && strings.Contains(argv[2], "command -v"):
			if have[argv[4]] {
				return starmod.RunResult{Stdout: "/usr/bin/" + argv[4] + "\n"}, true
			}
			return starmod.RunResult{RC: 1}, true
		case argv[0] == "nproc":
			return starmod.RunResult{Stdout: "2\n"}, true
		case len(argv) == 2 && (argv[1] == "--version" || argv[1] == "--help"):
			return starmod.RunResult{Stdout: argv[0] + " 1.0\n"}, true
		case argv[0] == "systemd-run":
			// The workload, started --no-block as a transient unit: its output lands in the files it names.
			for _, a := range argv {
				if f, ok := strings.CutPrefix(a, "StandardOutput=file:"); ok {
					h.files[f] = stdout
				}
				if f, ok := strings.CutPrefix(a, "StandardError=file:"); ok {
					h.files[f] = stderr
				}
			}
			return starmod.RunResult{}, true
		case argv[0] == "date":
			return starmod.RunResult{Stdout: "1792340000000000000\n"}, true
		case argv[0] == "timeout":
			return starmod.RunResult{}, true
		case argv[0] == "systemctl" && len(argv) > 2 && argv[1] == "show":
			return starmod.RunResult{Stdout: "0\n"}, true
		case argv[0] == "systemctl":
			return starmod.RunResult{}, true
		case strings.HasPrefix(argv[0], "/usr/bin/"):
			return starmod.RunResult{Stdout: stdout, Stderr: stderr}, true
		}
		return starmod.RunResult{}, false
	}
	return h
}

func TestBenchmarkParsesEachProfile(t *testing.T) {
	cases := []struct {
		profile, stdout, stderr, tool string
		want                          float64
		unit                          string
	}{
		{"sched_throughput", "Running in process mode with 10 groups using 40 file descriptors each (== 400 tasks)\nEach sender will pass 2000 messages of 100 bytes\nTime: 1.873\n", "", "hackbench", 1.873, "s"},
		{"cpu", "", "stress-ng: info:  [912] dispatching hogs: 2 cpu\nstress-ng: metrc: [912] stressor       bogo ops real time  usr time  sys time   bogo ops/s     bogo ops/s\nstress-ng: metrc: [912]                           (secs)    (secs)    (secs)   (real time) (usr+sys time)\nstress-ng: metrc: [912] cpu               41234     20.00     39.80      0.02      2061.70        1035.51\n", "stress-ng", 2061.70, "ops/s"},
		{"memory", "Total operations: 104857600 (5242333.18 per second)\n\n102400.00 MiB transferred (5119.47 MiB/sec)\n", "", "sysbench", 5119.47, "MiB/s"},
		{"io_randread", "{\n  \"jobs\" : [\n    {\n      \"read\" : {\n        \"io_bytes\" : 1,\n        \"bw\" : 40000,\n        \"iops\" : 10234.512,\n        \"clat_ns\" : {\n          \"percentile\" : {\n            \"99.000000\" : 456704\n          }\n        }\n      }\n    }\n  ]\n}\n", "", "fio", 10234.512, "IOPS"},
		// 100 samples per CPU; 99% at or below 12 µs, one sample per CPU at 40 µs.
		{"sched_latency", "# /dev/cpu_dma_latency set to 0us\n000005 000050 000050\n000012 000049 000049\n000040 000001 000001\n# Total: 000000100 000000100\n# Min Latencies: 00005 00005\n# Avg Latencies: 00006 00006\n# Max Latencies: 00040 00040\n# Histogram Overflows: 00000 00000\n", "", "cyclictest", 12, "us"},
	}
	for _, c := range cases {
		t.Run(c.profile, func(t *testing.T) {
			h := benchHost(c.stdout, c.stderr, c.tool)
			r, err := runModule(t, "benchmark", h, map[string]any{"profile": c.profile})
			if err != nil {
				t.Fatal(err)
			}
			d := dataOf(t, r)
			if d["value"] != c.want || d["unit"] != c.unit {
				t.Errorf("value=%v unit=%v, want %v %v (data %v)", d["value"], d["unit"], c.want, c.unit, d)
			}
			if d["tool_version"] == "" || d["command"] == "" {
				t.Errorf("missing provenance: %v", d)
			}
			if d["isolation"] != "transient systemd unit" {
				t.Errorf("workload not isolated from the agent unit: %v", d["isolation"])
			}
			started := false
			for _, m := range h.mutating {
				started = started || (m[0] == "systemd-run" && m[1] == "--no-block")
			}
			if !started {
				t.Errorf("no transient unit was started: %v", h.mutating)
			}
			for f := range h.files {
				if strings.HasPrefix(f, "/run/yoloman-benchmark-") {
					t.Errorf("output file %s left behind", f)
				}
			}
		})
	}
}

func TestBenchmarkRefusalsAndCheckMode(t *testing.T) {
	if _, err := runModule(t, "benchmark", benchHost("", ""), map[string]any{"profile": "sched_latency"}); err == nil ||
		!strings.Contains(err.Error(), "tool_unavailable: cyclictest is not installed (usually in the package rt-tests)") {
		t.Errorf("err = %v", err)
	}
	if _, err := runModule(t, "benchmark", benchHost("", "", "fio"), map[string]any{"profile": "io_randread", "path": "../etc"}); err == nil ||
		!strings.Contains(err.Error(), "existing absolute directory") {
		t.Errorf("err = %v", err)
	}
	h := benchHost("Time: 1.0\n", "", "hackbench")
	h.check = true
	r, err := runModule(t, "benchmark", h, map[string]any{"profile": "sched_throughput"})
	if err != nil || len(h.mutating) != 0 || dataOf(t, r)["value"] != nil {
		t.Errorf("check mode ran the workload: err=%v mutating=%v", err, h.mutating)
	}
	// More than 1% of the samples above the histogram: the p99 is not claimed.
	over := "000005 000090\n# Max Latencies: 25000\n# Histogram Overflows: 00010\n"
	r, err = runModule(t, "benchmark", benchHost(over, "", "cyclictest"), map[string]any{"profile": "sched_latency"})
	if err != nil {
		t.Fatal(err)
	}
	if d := dataOf(t, r); d["p99_beyond_histogram"] != true || d["value"] != float64(25000) {
		t.Errorf("overflow data = %v", d)
	}
}

// scxHost simulates the build: links in /usr/local/bin, the transient build unit, and what a finished build leaves.
type scxSim struct {
	tools   map[string]bool
	links   map[string]string // link → target
	unit    map[string]string // ActiveState, SubState, ExecMainStatus
	result  string            // what the started build does: "ok" | "fail" | "slow"
	starts  [][]string
	freeMB  int
	running bool // yoloman-sched-ext.service active
}

func scxHost(init string) (*fakeHost, *scxSim) {
	h := newFakeHost(init)
	sim := &scxSim{tools: map[string]bool{"git": true, "cargo": true, "rustc": true, "clang": true, "pkg-config": true, "make": true},
		links: map[string]string{}, unit: map[string]string{"ActiveState": "inactive", "SubState": "dead", "ExecMainStatus": "0"},
		result: "ok", freeMB: 20000}
	finish := func(h *fakeHost, ver string, scheds []string) {
		prefix := "/opt/yoloman/scx/" + ver
		for _, s := range scheds {
			h.files[prefix+"/bin/scx_"+s] = "ELF"
		}
		h.files[prefix+"/bin/BUILD-INFO"] = "version=" + ver + "\ncommit=abc123\nrustc=rustc 1.93.1\nbuilt=2026-10-18T17:00:00Z\n"
		for l, t := range sim.links {
			if strings.HasPrefix(t, "/opt/yoloman/scx/") {
				delete(sim.links, l)
			}
		}
		for _, s := range scheds {
			sim.links["/usr/local/bin/scx_"+s] = prefix + "/bin/scx_" + s
		}
	}
	h.handle = func(h *fakeHost, argv []string) (starmod.RunResult, bool) {
		switch {
		case argv[0] == "sh" && strings.Contains(argv[2], `printf "%s %s\n"`):
			var b strings.Builder
			for l, t := range sim.links {
				b.WriteString(l + " " + t + "\n")
			}
			return starmod.RunResult{Stdout: b.String()}, true
		case argv[0] == "sh" && strings.Contains(argv[2], "command -v"):
			if sim.tools[argv[4]] {
				return starmod.RunResult{Stdout: "/usr/bin/" + argv[4] + "\n"}, true
			}
			return starmod.RunResult{RC: 1}, true
		case argv[0] == "sh" && strings.Contains(argv[2], "ln -sfn") && !strings.Contains(argv[2], "cargo"):
			// _RELINK root bindir dir scheds...
			bindir := argv[5]
			for l, t := range sim.links {
				if strings.HasPrefix(t, "/opt/yoloman/scx/") {
					delete(sim.links, l)
				}
			}
			for _, s := range argv[7:] {
				sim.links[argv[6]+"/scx_"+s] = bindir + "/scx_" + s
			}
			return starmod.RunResult{}, true
		case argv[0] == "sh" && strings.Contains(argv[2], "ldd"):
			var b strings.Builder
			for _, f := range argv[4:] {
				if strings.HasPrefix(h.files[f], "NEEDS:") {
					b.WriteString("\t" + strings.TrimPrefix(h.files[f], "NEEDS:") + " => not found\n")
				}
			}
			return starmod.RunResult{Stdout: b.String()}, true
		case argv[0] == "df":
			return starmod.RunResult{Stdout: fmt.Sprintf("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 30000000 1 %d 1%% /\n", sim.freeMB*1024)}, true
		case argv[0] == "systemd-run":
			sim.starts = append(sim.starts, argv)
			i := slices.Index(argv, "-c")
			ver, scheds := argv[i+4], argv[i+7:]
			unit := ""
			for _, a := range argv {
				if u, ok := strings.CutPrefix(a, "--unit="); ok {
					unit = u
				}
			}
			switch sim.result {
			case "ok":
				finish(h, ver, scheds)
				sim.unit = map[string]string{"ActiveState": "active", "SubState": "exited", "ExecMainStatus": "0"}
			case "fail":
				h.files["/run/"+unit+".log"] = "Compiling libbpf-sys\nmake is required to compile libbpf-sys\nerror: build failed\n"
				sim.unit = map[string]string{"ActiveState": "failed", "SubState": "failed", "ExecMainStatus": "101"}
			default:
				sim.unit = map[string]string{"ActiveState": "active", "SubState": "running", "ExecMainStatus": "0"}
			}
			return starmod.RunResult{}, true
		case argv[0] == "systemctl" && argv[1] == "show":
			return starmod.RunResult{Stdout: "ActiveState=" + sim.unit["ActiveState"] + "\nSubState=" + sim.unit["SubState"] + "\nExecMainStatus=" + sim.unit["ExecMainStatus"] + "\n"}, true
		case argv[0] == "systemctl" && argv[1] == "is-active":
			if sim.running {
				return starmod.RunResult{}, true
			}
			return starmod.RunResult{RC: 3}, true
		case argv[0] == "systemctl" && (argv[1] == "stop" || argv[1] == "reset-failed"):
			sim.unit = map[string]string{"ActiveState": "inactive", "SubState": "dead", "ExecMainStatus": "0"}
			return starmod.RunResult{}, true
		case argv[0] == "timeout":
			return starmod.RunResult{}, true
		case argv[0] == "rm":
			for _, a := range argv[1:] {
				delete(sim.links, a)
				for p := range h.files {
					if p == a || strings.HasPrefix(p, a+"/") {
						delete(h.files, p)
					}
				}
			}
			return starmod.RunResult{}, true
		}
		return starmod.RunResult{}, false
	}
	return h, sim
}

func TestScxInstallBuildsLinksAndIsIdempotent(t *testing.T) {
	h, sim := scxHost("systemd")
	r, err := runModule(t, "scx_install", h, map[string]any{"schedulers": []any{"rusty", "bpfland"}, "proxy": "http://proxy.example:3128"})
	if err != nil {
		t.Fatal(err)
	}
	d := dataOf(t, r)
	if !r.Changed || d["after"].(map[string]any)["state"] != "built" || d["after"].(map[string]any)["linked"] != true {
		t.Fatalf("changed=%v after=%v", r.Changed, d["after"])
	}
	if sim.links["/usr/local/bin/scx_bpfland"] != "/opt/yoloman/scx/v1.1.4/bin/scx_bpfland" {
		t.Errorf("links = %v", sim.links)
	}
	start := strings.Join(sim.starts[0], " ")
	for _, want := range []string{"--unit=yoloman-scx-build-v1-1-4.service", "Nice=10", "IOSchedulingClass=idle", "--setenv=https_proxy=http://proxy.example:3128"} {
		if !strings.Contains(start, want) {
			t.Errorf("build unit lacks %q: %s", want, start)
		}
	}
	if rb := d["rollback"].(map[string]any); rb["state"] != "absent" || rb["version"] != "v1.1.4" {
		t.Errorf("rollback = %v", rb)
	}
	if r, err := runModule(t, "scx_install", h, map[string]any{"schedulers": []any{"rusty", "bpfland"}}); err != nil || r.Changed || len(sim.starts) != 1 {
		t.Errorf("second run changed=%v err=%v builds=%d", r.Changed, err, len(sim.starts))
	}
}

func TestScxInstallBuildingIsNotStartedTwiceAndFailureShowsTheLog(t *testing.T) {
	h, sim := scxHost("systemd")
	sim.result = "slow"
	r, err := runModule(t, "scx_install", h, map[string]any{"wait": 1})
	if err != nil || !r.Changed || dataOf(t, r)["after"].(map[string]any)["state"] != "building" {
		t.Fatalf("first call: changed=%v err=%v", r.Changed, err)
	}
	if r, err := runModule(t, "scx_install", h, map[string]any{"wait": 1}); err != nil || r.Changed || len(sim.starts) != 1 {
		t.Errorf("a running build was started again: changed=%v err=%v builds=%d", r.Changed, err, len(sim.starts))
	}
	// The build fails: the call says so with the log tail, and clears the unit so the next call starts over.
	h.files["/run/yoloman-scx-build-v1-1-4.service.log"] = "Compiling libbpf-sys\nmake is required to compile libbpf-sys\n"
	sim.unit = map[string]string{"ActiveState": "failed", "SubState": "failed", "ExecMainStatus": "101"}
	if _, err := runModule(t, "scx_install", h, nil); err == nil || !strings.Contains(err.Error(), "make is required") || !strings.Contains(err.Error(), "call again") {
		t.Errorf("err = %v", err)
	}
	sim.result = "ok"
	if r, err := runModule(t, "scx_install", h, nil); err != nil || !r.Changed || len(sim.starts) != 2 {
		t.Errorf("retry after failure: changed=%v err=%v builds=%d", r.Changed, err, len(sim.starts))
	}
}

func TestScxInstallSwitchesVersionAndRollsBackByRelinking(t *testing.T) {
	h, sim := scxHost("systemd")
	if _, err := runModule(t, "scx_install", h, map[string]any{"version": "v1.1.3", "schedulers": []any{"rusty"}}); err != nil {
		t.Fatal(err)
	}
	r, err := runModule(t, "scx_install", h, map[string]any{"version": "v1.1.4", "schedulers": []any{"bpfland"}})
	if err != nil {
		t.Fatal(err)
	}
	rb := dataOf(t, r)["rollback"].(map[string]any)
	if rb["state"] != "present" || rb["version"] != "v1.1.3" || fmt.Sprint(rb["schedulers"]) != "[rusty]" {
		t.Fatalf("rollback = %v", rb)
	}
	if _, ok := sim.links["/usr/local/bin/scx_rusty"]; ok {
		t.Errorf("a link of the old version survived: %v", sim.links)
	}
	// The rollback finds v1.1.3 still built and only relinks it — no second build of that version.
	if _, err := runModule(t, "scx_install", h, map[string]any{"version": "v1.1.3", "schedulers": []any{"rusty"}}); err != nil {
		t.Fatal(err)
	}
	if len(sim.starts) != 2 || sim.links["/usr/local/bin/scx_rusty"] != "/opt/yoloman/scx/v1.1.3/bin/scx_rusty" || len(sim.links) != 1 {
		t.Errorf("builds=%d links=%v", len(sim.starts), sim.links)
	}
}

func TestScxInstallRefusalsAndAbsent(t *testing.T) {
	h, sim := scxHost("systemd")
	sim.tools["make"] = false
	if _, err := runModule(t, "scx_install", h, nil); err == nil || !strings.Contains(err.Error(), "tool_unavailable: make") || !strings.Contains(err.Error(), "libelf-dev") {
		t.Errorf("err = %v", err)
	}
	sim.tools["make"] = true
	sim.freeMB = 1000
	if _, err := runModule(t, "scx_install", h, nil); err == nil || !strings.Contains(err.Error(), "unsupported: /var/tmp has 1000 MB") {
		t.Errorf("err = %v", err)
	}
	sim.freeMB = 20000
	for _, v := range []string{"latest", "1.1.4", "v1.1"} {
		if _, err := runModule(t, "scx_install", h, map[string]any{"version": v}); err == nil || !strings.Contains(err.Error(), "release tag") {
			t.Errorf("version %q: err = %v", v, err)
		}
	}
	h.files["/usr/local/bin/scx_lavd"] = "someone else's binary"
	if _, err := runModule(t, "scx_install", h, nil); err == nil || !strings.Contains(err.Error(), "conflict: /usr/local/bin/scx_lavd") {
		t.Errorf("err = %v", err)
	}
	delete(h.files, "/usr/local/bin/scx_lavd")
	if len(sim.starts) != 0 {
		t.Fatalf("a refused call started a build")
	}
	if oh, _ := scxHost("openrc"); true {
		if _, err := runModule(t, "scx_install", oh, nil); err == nil || !strings.Contains(err.Error(), "unsupported: the build runs as a transient systemd unit") {
			t.Errorf("openrc: err = %v", err)
		}
	}
	// absent: refused while yoloman.sched_ext runs a scheduler from this build, then removes binaries and links.
	if _, err := runModule(t, "scx_install", h, nil); err != nil {
		t.Fatal(err)
	}
	h.files["/etc/systemd/system/yoloman-sched-ext.service"] = "[Service]\nExecStart=/usr/local/bin/scx_bpfland\n"
	sim.running = true
	if _, err := runModule(t, "scx_install", h, map[string]any{"state": "absent"}); err == nil || !strings.Contains(err.Error(), "conflict: yoloman.sched_ext runs") {
		t.Errorf("err = %v", err)
	}
	sim.running = false
	r, err := runModule(t, "scx_install", h, map[string]any{"state": "absent"})
	if err != nil || !r.Changed || len(sim.links) != 0 || h.files["/opt/yoloman/scx/v1.1.4/bin/scx_rusty"] != "" {
		t.Errorf("absent: changed=%v err=%v links=%v", r.Changed, err, sim.links)
	}
	if rb := dataOf(t, r)["rollback"].(map[string]any); rb["state"] != "present" {
		t.Errorf("rollback of absent = %v", rb)
	}
}

func TestScxInstallLinksTheBundledBuildWithoutCompiling(t *testing.T) {
	h, sim := scxHost("systemd")
	for _, s := range []string{"rusty", "bpfland", "lavd"} {
		h.files["/usr/lib/yoloman/scx/v1.1.4/scx_"+s] = "ELF"
	}
	h.files["/usr/lib/yoloman/scx/v1.1.4/BUILD-INFO"] = "commit=e7b3a21\nrustc=rustc 1.93.0\nbuilt=2026-10-18T18:30:00Z\n"
	sim.tools["cargo"] = false // no compiler needed for the bundled build
	r, err := runModule(t, "scx_install", h, nil)
	if err != nil {
		t.Fatal(err)
	}
	d := dataOf(t, r)
	if !r.Changed || len(sim.starts) != 0 || sim.links["/usr/local/bin/scx_bpfland"] != "/usr/lib/yoloman/scx/v1.1.4/scx_bpfland" {
		t.Fatalf("changed=%v builds=%d links=%v", r.Changed, len(sim.starts), sim.links)
	}
	if d["after"].(map[string]any)["source"] != "bundled" || d["after"].(map[string]any)["commit"] != "e7b3a21" {
		t.Errorf("after = %v", d["after"])
	}
	if r, err := runModule(t, "scx_install", h, nil); err != nil || r.Changed {
		t.Errorf("second run changed=%v err=%v", r.Changed, err)
	}
	// source=upstream builds anyway (here refused: no cargo); a missing library is named with its package.
	if _, err := runModule(t, "scx_install", h, map[string]any{"source": "upstream"}); err == nil || !strings.Contains(err.Error(), "tool_unavailable: cargo") {
		t.Errorf("upstream err = %v", err)
	}
	h.files["/usr/lib/yoloman/scx/v1.1.4/scx_lavd"] = "NEEDS:libelf.so.1"
	for l := range sim.links {
		delete(sim.links, l)
	}
	if _, err := runModule(t, "scx_install", h, nil); err == nil || !strings.Contains(err.Error(), "libelf.so.1") || !strings.Contains(err.Error(), "libelf1t64") {
		t.Errorf("missing-lib err = %v", err)
	}
	// absent drops the links only — the package owns the bundled files.
	h.files["/usr/lib/yoloman/scx/v1.1.4/scx_lavd"] = "ELF"
	if _, err := runModule(t, "scx_install", h, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := runModule(t, "scx_install", h, map[string]any{"state": "absent"}); err != nil || len(sim.links) != 0 || h.files["/usr/lib/yoloman/scx/v1.1.4/scx_rusty"] != "ELF" {
		t.Errorf("absent: err=%v links=%v", err, sim.links)
	}
	if _, err := runModule(t, "scx_install", h, map[string]any{"source": "bundled", "version": "v1.1.3"}); err == nil || !strings.Contains(err.Error(), "carries no scx v1.1.3") {
		t.Errorf("bundled-missing err = %v", err)
	}
}
