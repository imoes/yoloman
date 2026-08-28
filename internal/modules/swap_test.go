package modules

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The swap module owns the RUNTIME area (create/mkswap/swapon/swapoff). It deliberately does not
// touch /etc/fstab — that line belongs to the fstab codec, and two writers for one file is how a
// config grows duplicate entries. These tests pin the destructive guard and the idempotence, which
// are the two properties an operator's data depends on.

type recordingRunner struct {
	calls  []string
	fail   map[string]error
	output map[string]string
}

func (r *recordingRunner) run(_ context.Context, name string, args ...string) ([]byte, error) {
	call := strings.TrimSpace(name + " " + strings.Join(args, " "))
	r.calls = append(r.calls, call)
	if err, ok := r.fail[name]; ok {
		return []byte(r.output[name]), err
	}
	return []byte(r.output[name]), nil
}

func (r *recordingRunner) ran(prefix string) bool {
	for _, c := range r.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func swapModule(r *recordingRunner) *Swap {
	return &Swap{Runner: r.run, LookPath: func(b string) (string, error) { return "/sbin/" + b, nil }}
}

func TestSwapRefusesToFormatADeviceHoldingAFilesystem(t *testing.T) {
	// The whole point of the guard: mkswap on a disk that carries ext4 destroys it, and "it was in
	// the storage tab" is no comfort afterwards.
	r := &recordingRunner{output: map[string]string{"blkid": "ext4\n"}}
	// A path that exists but is not a regular file stands in for a block device.
	_, err := swapModule(r).Run(context.Background(), map[string]any{"path": "/dev", "state": "present"}, false)
	if err == nil {
		t.Fatal("mkswap on a device with a filesystem was allowed")
	}
	if !strings.Contains(err.Error(), "ext4") || !strings.Contains(err.Error(), "force") {
		t.Fatalf("the refusal must name what it found and how to override: %v", err)
	}
	if r.ran("mkswap") {
		t.Fatal("mkswap ran despite the refusal")
	}
}

func TestSwapForceOverridesTheGuard(t *testing.T) {
	// The refusal has to be overridable, or reusing an old data disk becomes impossible — but only
	// by saying so explicitly.
	r := &recordingRunner{output: map[string]string{"blkid": "ext4\n"}}
	_, err := swapModule(r).Run(context.Background(),
		map[string]any{"path": "/dev", "state": "present", "force": true}, false)
	if err != nil {
		t.Fatalf("force should allow it: %v", err)
	}
	if !r.ran("mkswap /dev") || !r.ran("swapon") {
		t.Fatalf("expected mkswap + swapon, got %v", r.calls)
	}
}

func TestSwapSkipsMkswapOnAnExistingSwapArea(t *testing.T) {
	// Re-running must not reformat: mkswap on a live area changes its UUID and orphans the fstab
	// line that referenced it.
	r := &recordingRunner{output: map[string]string{"blkid": "swap\n"}}
	_, err := swapModule(r).Run(context.Background(), map[string]any{"path": "/dev", "state": "present"}, false)
	if err != nil {
		t.Fatal(err)
	}
	if r.ran("mkswap") {
		t.Fatal("mkswap ran on something blkid already reported as swap")
	}
	if !r.ran("swapon") {
		t.Fatal("expected swapon")
	}
}

func TestSwapRefusesANewFileWithoutASize(t *testing.T) {
	r := &recordingRunner{}
	_, err := swapModule(r).Run(context.Background(),
		map[string]any{"path": filepath.Join(t.TempDir(), "swapfile"), "state": "present"}, false)
	if err == nil {
		t.Fatal("a missing file with no size must be refused, not invented")
	}
	if !strings.Contains(err.Error(), "size") {
		t.Fatalf("the error must say what is missing: %v", err)
	}
}

func TestSwapCreatesAFileWithPrivatePermissions(t *testing.T) {
	// A world-readable swap file exposes whatever the kernel paged out. mkswap only warns, so the
	// mode is set before it rather than relying on the warning being noticed.
	dir := t.TempDir()
	path := filepath.Join(dir, "swapfile")
	r := &recordingRunner{}
	// fallocate is faked: create the file so the later chmod has something to act on.
	r.fail = map[string]error{}
	m := swapModule(r)
	m.Runner = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name == "fallocate" {
			if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
				return nil, err
			}
		}
		return r.run(ctx, name, args...)
	}
	if _, err := m.Run(context.Background(),
		map[string]any{"path": path, "state": "present", "size": "8M"}, false); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("swap file mode is %o, want 600", fi.Mode().Perm())
	}
	if !r.ran("mkswap") || !r.ran("swapon") {
		t.Fatalf("expected mkswap + swapon after creating, got %v", r.calls)
	}
}

func TestSwapFallsBackToDdWhenFallocateFails(t *testing.T) {
	// Some filesystems have no fallocate. The fallback must be real, not a silent failure.
	path := filepath.Join(t.TempDir(), "swapfile")
	r := &recordingRunner{fail: map[string]error{"fallocate": errors.New("not supported")}}
	m := swapModule(r)
	m.Runner = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		out, err := r.run(ctx, name, args...)
		if name == "dd" {
			_ = os.WriteFile(path, []byte("x"), 0o644)
		}
		return out, err
	}
	if _, err := m.Run(context.Background(),
		map[string]any{"path": path, "state": "present", "size": "2G"}, false); err != nil {
		t.Fatal(err)
	}
	if !r.ran("dd if=/dev/zero of=" + path + " bs=1M count=2048") {
		t.Fatalf("dd fallback not used with the right block count: %v", r.calls)
	}
}

func TestSwapDryRunTouchesNothingButListsTheSteps(t *testing.T) {
	path := filepath.Join(t.TempDir(), "swapfile")
	r := &recordingRunner{}
	res, err := swapModule(r).Run(context.Background(),
		map[string]any{"path": path, "state": "present", "size": "1G"}, true)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Changed {
		t.Fatal("a dry run must still report that something would change")
	}
	if len(r.calls) != 0 {
		t.Fatalf("dry run executed commands: %v", r.calls)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("dry run created the file")
	}
	steps := res.Data.(map[string]any)["steps"].([]string)
	if len(steps) != 3 {
		t.Fatalf("expected create + mkswap + swapon, got %v", steps)
	}
}

func TestSwapAbsentOnAnInactiveAreaIsNotAChange(t *testing.T) {
	r := &recordingRunner{}
	res, err := swapModule(r).Run(context.Background(),
		map[string]any{"path": "/nonexistent-swap", "state": "absent"}, false)
	if err != nil {
		t.Fatal(err)
	}
	if res.Changed {
		t.Fatal("swapping off something that is not on is not a change")
	}
	if r.ran("swapoff") {
		t.Fatal("swapoff ran on an inactive area")
	}
}

func TestSwapNeverDeletesWithoutBeingAsked(t *testing.T) {
	// Swapping off is reversible; deleting is not. The default must be the reversible one.
	path := filepath.Join(t.TempDir(), "swapfile")
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := &recordingRunner{}
	if _, err := swapModule(r).Run(context.Background(),
		map[string]any{"path": path, "state": "absent"}, false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("the swap file was deleted without remove_file")
	}
}

func TestSwapReadListsTheActiveAreas(t *testing.T) {
	// Reading needs no path and must never report a change — it is the observation half.
	res, err := swapModule(&recordingRunner{}).Run(context.Background(), map[string]any{}, false)
	if err != nil {
		t.Fatal(err)
	}
	if res.Changed {
		t.Fatal("a read reported a change")
	}
	if _, ok := res.Data.(map[string]any)["areas"]; !ok {
		t.Fatal("no areas in the result")
	}
}

func TestDdCountForRejectsWhatItCannotConvert(t *testing.T) {
	for _, ok := range []struct {
		in   string
		want int
	}{{"2G", 2048}, {"512M", 512}, {"1g", 1024}} {
		got, err := ddCountFor(ok.in)
		if err != nil || got != ok.want {
			t.Fatalf("%q → %d, %v (want %d)", ok.in, got, err, ok.want)
		}
	}
	for _, bad := range []string{"2T", "abc", "0M", "-1G", ""} {
		if _, err := ddCountFor(bad); err == nil {
			t.Fatalf("%q was accepted", bad)
		}
	}
}
