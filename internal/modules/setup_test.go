package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func newTestSetup(t *testing.T) *Setup {
	t.Helper()
	root := t.TempDir()

	write := func(rel, content string) {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("sys/kernel/osrelease", "6.17.0-35-generic\n")
	write("meminfo", "MemTotal:       2048 kB\n")
	write("cpuinfo", "processor\t: 0\nvendor_id\t: GenuineIntel\n\nprocessor\t: 1\nvendor_id\t: GenuineIntel\n\n")

	osRelease := filepath.Join(root, "os-release")
	if err := os.WriteFile(osRelease, []byte("NAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	return &Setup{
		ProcRoot:      root,
		OSReleasePath: osRelease,
		Architecture:  "x86_64",
		HostnameFunc:  func() (string, error) { return "test-host", nil },
	}
}

func TestSetup_GathersFacts(t *testing.T) {
	s := newTestSetup(t)
	res, err := s.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("setup is read-only, expected Changed=false")
	}
	facts, ok := res.Data.(map[string]any)
	if !ok {
		t.Fatalf("expected Data to be map[string]any, got %T", res.Data)
	}

	want := map[string]any{
		"ansible_hostname":             "test-host",
		"ansible_architecture":         "x86_64",
		"ansible_kernel":               "6.17.0-35-generic",
		"ansible_distribution":         "Ubuntu",
		"ansible_distribution_version": "24.04",
		"ansible_memtotal_mb":          int64(2),
		"ansible_processor_vcpus":      2,
	}
	for k, v := range want {
		if facts[k] != v {
			t.Errorf("facts[%q] = %v (%T), want %v (%T)", k, facts[k], facts[k], v, v)
		}
	}
}

func TestSetup_ModuleIsReadOnly(t *testing.T) {
	s := NewSetup()
	if s.Writes() {
		t.Error("setup module must be read-only")
	}
	if s.Name() != "setup" {
		t.Errorf("Name() = %q, want setup", s.Name())
	}
}

func TestUnameArch(t *testing.T) {
	cases := map[string]string{
		"amd64": "x86_64",
		"arm64": "aarch64",
		"386":   "i686",
		"riscv": "riscv", // unknown arch passes through unchanged
	}
	for in, want := range cases {
		if got := unameArch(in); got != want {
			t.Errorf("unameArch(%q) = %q, want %q", in, got, want)
		}
	}
}
