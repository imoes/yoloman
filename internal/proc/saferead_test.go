package proc

import (
	"os"
	"path/filepath"
	"testing"
)

// newFakeProcRoot builds a small directory tree mimicking /proc, including a
// symlink that legitimately stays inside root and one that escapes it (like
// /proc/<pid>/exe would).
func newFakeProcRoot(t *testing.T) (root, secretOutsideRoot string) {
	t.Helper()
	base := t.TempDir()

	root = filepath.Join(base, "proc")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(filepath.Join(root, "meminfo"), []byte("MemTotal: 123 kB\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Legit in-root symlink, like /proc/mounts -> self/mounts.
	if err := os.Symlink("meminfo", filepath.Join(root, "meminfo_link")); err != nil {
		t.Fatal(err)
	}

	// A file outside the fake proc root that a malicious symlink might point to.
	outside := filepath.Join(base, "secret.txt")
	if err := os.WriteFile(outside, []byte("outside contents"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Escaping symlink, like /proc/<pid>/exe pointing at a real binary.
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}

	return root, outside
}

func TestSafeRead_NormalFile(t *testing.T) {
	root, _ := newFakeProcRoot(t)
	data, err := SafeRead(root, "meminfo", 0)
	if err != nil {
		t.Fatalf("SafeRead: %v", err)
	}
	if string(data) != "MemTotal: 123 kB\n" {
		t.Errorf("unexpected contents: %q", data)
	}
}

func TestSafeRead_InRootSymlinkAllowed(t *testing.T) {
	root, _ := newFakeProcRoot(t)
	data, err := SafeRead(root, "meminfo_link", 0)
	if err != nil {
		t.Fatalf("SafeRead: %v", err)
	}
	if string(data) != "MemTotal: 123 kB\n" {
		t.Errorf("unexpected contents: %q", data)
	}
}

func TestSafeRead_DotDotTraversalRejected(t *testing.T) {
	root, _ := newFakeProcRoot(t)
	if _, err := SafeRead(root, "../secret.txt", 0); err == nil {
		t.Fatal("expected error for '..' traversal")
	}
	if _, err := SafeRead(root, "../../../../../../etc/passwd", 0); err == nil {
		t.Fatal("expected error for deep '..' traversal")
	}
}

func TestSafeRead_EscapingSymlinkRejected(t *testing.T) {
	root, _ := newFakeProcRoot(t)
	if _, err := SafeRead(root, "escape", 0); err == nil {
		t.Fatal("expected error for symlink escaping root")
	}
}

func TestSafeRead_MaxBytesEnforced(t *testing.T) {
	root, _ := newFakeProcRoot(t)
	if err := os.WriteFile(filepath.Join(root, "big"), []byte("0123456789"), 0o644); err != nil {
		t.Fatal(err)
	}
	data, err := SafeRead(root, "big", 4)
	if err != nil {
		t.Fatalf("SafeRead: %v", err)
	}
	if string(data) != "0123" {
		t.Errorf("expected truncated read %q, got %q", "0123", data)
	}
}

func TestSafeRead_NonexistentFile(t *testing.T) {
	root, _ := newFakeProcRoot(t)
	if _, err := SafeRead(root, "does-not-exist", 0); err == nil {
		t.Fatal("expected error for nonexistent file")
	}
}
