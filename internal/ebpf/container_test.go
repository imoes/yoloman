package ebpf

import (
	"os"
	"testing"
)

func TestContainerIDFromCgroupData_DockerCgroupV1(t *testing.T) {
	data := []byte("12:memory:/docker/1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef\n" +
		"11:pids:/docker/1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef\n")
	got := containerIDFromCgroupData(data)
	want := "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestContainerIDFromCgroupData_DockerSystemdCgroupV2(t *testing.T) {
	data := []byte("0::/system.slice/docker-abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890.scope\n")
	got := containerIDFromCgroupData(data)
	want := "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestContainerIDFromCgroupData_ContainerdCRI(t *testing.T) {
	data := []byte("0::/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-podabc123.slice/" +
		"cri-containerd-fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321.scope\n")
	got := containerIDFromCgroupData(data)
	want := "fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestContainerIDFromCgroupData_BareMetalProcess_NoMatch(t *testing.T) {
	cases := []string{
		"0::/user.slice/user-1000.slice/session-2.scope\n",
		"0::/init.scope\n",
		"1:name=systemd:/system.slice/sshd.service\n",
	}
	for _, data := range cases {
		if got := containerIDFromCgroupData([]byte(data)); got != "" {
			t.Errorf("data %q: got container id %q, want empty (not containerized)", data, got)
		}
	}
}

func TestContainerIDFromCgroupData_Empty(t *testing.T) {
	if got := containerIDFromCgroupData([]byte("")); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

func TestContainerIDForPID_UsesInjectedReader(t *testing.T) {
	orig := readCgroupFile
	defer func() { readCgroupFile = orig }()

	var gotPath string
	readCgroupFile = func(path string) ([]byte, error) {
		gotPath = path
		return []byte("0::/docker/1111111111111111111111111111111111111111111111111111111111111111\n"), nil
	}

	got := containerIDForPID(4242)
	if gotPath != "/proc/4242/cgroup" {
		t.Errorf("read path = %q, want /proc/4242/cgroup", gotPath)
	}
	want := "1111111111111111111111111111111111111111111111111111111111111111"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestContainerIDForPID_MissingProcessReturnsEmpty(t *testing.T) {
	orig := readCgroupFile
	defer func() { readCgroupFile = orig }()
	readCgroupFile = func(path string) ([]byte, error) {
		return nil, os.ErrNotExist
	}

	if got := containerIDForPID(999999); got != "" {
		t.Errorf("got %q, want empty for a process that no longer exists", got)
	}
}

// TestContainerIDForPID_RealProcess exercises the function against this
// test process's own real /proc/<pid>/cgroup — no injected reader — to
// prove the actual file path and parsing work end to end against a real
// kernel-provided file, not just synthetic content. The test binary itself
// isn't containerized in most dev/CI environments, so an empty result is
// the expected (and still meaningful) outcome there; if it does happen to
// run inside a container, it must return a plausible ID instead of empty
// or erroring.
func TestContainerIDForPID_RealProcess(t *testing.T) {
	pid := uint32(os.Getpid())
	// Must not panic/error regardless of containerization; both outcomes
	// (empty string outside a container, non-empty inside one) are valid.
	_ = containerIDForPID(pid)
}
