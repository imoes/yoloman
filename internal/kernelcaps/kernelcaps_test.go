package kernelcaps

import (
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func roots(t *testing.T) (*Detector, string) {
	base := t.TempDir()
	d := &Detector{
		ProcRoot: filepath.Join(base, "proc"),
		SysRoot:  filepath.Join(base, "sys"),
		BootRoot: filepath.Join(base, "boot"),
		RunRoot:  filepath.Join(base, "run"),
	}
	write(t, filepath.Join(d.ProcRoot, "sys/kernel/osrelease"), "6.12.9-test\n")
	return d, base
}

// A modern host: BTF, readable /boot config, sched_ext with bpfland attached,
// GRUB, systemd.
func TestDetectEnabledSchedExt(t *testing.T) {
	d, _ := roots(t)
	write(t, filepath.Join(d.SysRoot, "kernel/btf/vmlinux"), "btf")
	write(t, filepath.Join(d.BootRoot, "config-6.12.9-test"),
		"CONFIG_SCHED_CLASS_EXT=y\nCONFIG_DEBUG_INFO_BTF=y\n# CONFIG_PSI is not set\nCONFIG_BPF_JIT=y\n")
	write(t, filepath.Join(d.SysRoot, "kernel/sched_ext/state"), "enabled\n")
	write(t, filepath.Join(d.SysRoot, "kernel/sched_ext/root/ops"), "bpfland_1.0.8_x86_64\n")
	write(t, filepath.Join(d.BootRoot, "grub/grub.cfg"), "")
	if err := os.MkdirAll(filepath.Join(d.RunRoot, "systemd/system"), 0o755); err != nil {
		t.Fatal(err)
	}

	c := d.Detect()
	if c.Release != "6.12.9-test" {
		t.Errorf("release = %q", c.Release)
	}
	if c.BTF.State != "present" {
		t.Errorf("btf = %+v", c.BTF)
	}
	if c.SchedExt.State != "enabled" || c.SchedExt.Ops != "bpfland_1.0.8_x86_64" {
		t.Errorf("sched_ext = %+v", c.SchedExt)
	}
	if c.Config.Flags["CONFIG_SCHED_CLASS_EXT"] != "y" || c.Config.Flags["CONFIG_PSI"] != "n" {
		t.Errorf("flags = %v", c.Config.Flags)
	}
	if c.Boot.State != "grub" || c.Init.State != "systemd" {
		t.Errorf("boot = %+v init = %+v", c.Boot, c.Init)
	}
}

// /proc/config.gz wins over /boot, and a kernel built without sched_ext says
// so with the config source as its reason.
func TestDetectUnsupportedFromProcConfig(t *testing.T) {
	d, _ := roots(t)
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	gz.Write([]byte("# CONFIG_SCHED_CLASS_EXT is not set\nCONFIG_BPF_SYSCALL=y\n"))
	gz.Close()
	write(t, filepath.Join(d.ProcRoot, "config.gz"), buf.String())
	write(t, filepath.Join(d.BootRoot, "config-6.12.9-test"), "CONFIG_SCHED_CLASS_EXT=y\n")

	c := d.Detect()
	if c.Config.Source != filepath.Join(d.ProcRoot, "config.gz") {
		t.Errorf("source = %q", c.Config.Source)
	}
	if c.SchedExt.State != "unsupported" || c.SchedExt.Reason == "" {
		t.Errorf("sched_ext = %+v", c.SchedExt)
	}
	if c.BTF.State != "absent" {
		t.Errorf("btf = %+v", c.BTF)
	}
}

// Nothing readable: every field is a named state with evidence, none empty.
func TestDetectNothingReadable(t *testing.T) {
	d, _ := roots(t)
	c := d.Detect()
	if c.Config.Source != "unknown" {
		t.Errorf("config source = %q", c.Config.Source)
	}
	if c.SchedExt.State != "unsupported" || c.SchedExt.Reason == "" {
		t.Errorf("sched_ext = %+v", c.SchedExt)
	}
	for name, v := range map[string]Verdict{"boot": c.Boot, "init": c.Init} {
		if v.State != "unknown" || v.Evidence == "" {
			t.Errorf("%s = %+v", name, v)
		}
	}
}

// systemd-boot is proven by its EFI variable even when a stale grub.cfg exists.
func TestBootLoaderPrefersEFIEvidence(t *testing.T) {
	d, _ := roots(t)
	write(t, filepath.Join(d.SysRoot, "firmware/efi/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"), "x")
	write(t, filepath.Join(d.BootRoot, "grub/grub.cfg"), "")
	if got := d.Detect().Boot.State; got != "systemd-boot" {
		t.Errorf("boot = %q", got)
	}
}

func TestUnrecognisedSchedExtState(t *testing.T) {
	d, _ := roots(t)
	write(t, filepath.Join(d.SysRoot, "kernel/sched_ext/state"), "weird\n")
	if got := d.Detect().SchedExt; got.State != "unknown" || got.Reason == "" {
		t.Errorf("sched_ext = %+v", got)
	}
}

func TestCollectorStatus(t *testing.T) {
	SetCollectorStatus("failed", "operation not permitted")
	t.Cleanup(func() { SetCollectorStatus("not_started", "") })
	if got := CollectorStatus(); got.State != "failed" || got.Reason != "operation not permitted" {
		t.Errorf("collector = %+v", got)
	}
}
