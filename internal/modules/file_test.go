package modules

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
)

func TestFile_DirectoryCreatesThenIdempotent(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "sub", "nested")
	f := NewFile()

	res, err := f.Run(context.Background(), map[string]any{"path": dir, "state": "directory"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true on first creation")
	}
	fi, err := os.Stat(dir)
	if err != nil || !fi.IsDir() {
		t.Fatalf("expected directory to exist, err=%v", err)
	}

	res2, err := f.Run(context.Background(), map[string]any{"path": dir, "state": "directory"}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res2.Changed {
		t.Error("expected changed=false on idempotent 2nd run")
	}
}

func TestFile_DirectoryDryRunDoesNotCreate(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "would-exist")
	f := NewFile()

	res, err := f.Run(context.Background(), map[string]any{"path": dir, "state": "directory", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("expected directory to NOT exist after dry_run, err=%v", err)
	}
}

func TestFile_AbsentRemovesThenIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "victim.txt")
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	f := NewFile()
	res, err := f.Run(context.Background(), map[string]any{"path": path, "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing existing file")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("expected file to be removed")
	}

	res2, err := f.Run(context.Background(), map[string]any{"path": path, "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res2.Changed {
		t.Error("expected changed=false when already absent")
	}
}

func TestFile_TouchCreatesFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "touched.txt")
	f := NewFile()

	res, err := f.Run(context.Background(), map[string]any{"path": path, "state": "touch"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true creating new file")
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("expected file to exist: %v", err)
	}
}

func TestFile_StateFileErrorsWhenMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nope.txt")
	f := NewFile()
	if _, err := f.Run(context.Background(), map[string]any{"path": path, "state": "file"}, false); err == nil {
		t.Fatal("expected error asserting attributes on a nonexistent path with state=file")
	}
}

func TestFile_ModeAttributeChange(t *testing.T) {
	path := filepath.Join(t.TempDir(), "perms.txt")
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	f := NewFile()

	res, err := f.Run(context.Background(), map[string]any{"path": path, "state": "file", "mode": "0644"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when mode differs")
	}
	fi, _ := os.Stat(path)
	if fi.Mode().Perm() != 0o644 {
		t.Errorf("mode = %o, want 0644", fi.Mode().Perm())
	}

	res2, err := f.Run(context.Background(), map[string]any{"path": path, "state": "file", "mode": "0644"}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res2.Changed {
		t.Error("expected changed=false when mode already matches")
	}
}

func TestFile_InvalidState(t *testing.T) {
	f := NewFile()
	if _, err := f.Run(context.Background(), map[string]any{"path": "/tmp/x", "state": "bogus"}, false); err == nil {
		t.Fatal("expected error for invalid state")
	}
}

func TestFile_LinkCreatesThenIdempotent(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real-target")
	link := filepath.Join(dir, "the-link")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	f := NewFile()

	res, err := f.Run(context.Background(), map[string]any{"path": link, "src": target, "state": "link"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true on first symlink creation")
	}
	got, err := os.Readlink(link)
	if err != nil || got != target {
		t.Fatalf("expected symlink -> %q, got %q (err=%v)", target, got, err)
	}

	res2, err := f.Run(context.Background(), map[string]any{"path": link, "src": target, "state": "link"}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res2.Changed {
		t.Error("expected changed=false on idempotent 2nd run")
	}
}

func TestFile_LinkDryRunDoesNotCreate(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real-target")
	link := filepath.Join(dir, "the-link")
	f := NewFile()

	res, err := f.Run(context.Background(), map[string]any{"path": link, "src": target, "state": "link", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Lstat(link); !os.IsNotExist(err) {
		t.Errorf("expected symlink to NOT exist after dry_run, err=%v", err)
	}
}

func TestFile_LinkRetargetsWhenSrcDiffers(t *testing.T) {
	dir := t.TempDir()
	oldTarget := filepath.Join(dir, "old-target")
	newTarget := filepath.Join(dir, "new-target")
	link := filepath.Join(dir, "the-link")
	if err := os.Symlink(oldTarget, link); err != nil {
		t.Fatal(err)
	}
	f := NewFile()

	res, err := f.Run(context.Background(), map[string]any{"path": link, "src": newTarget, "state": "link"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when retargeting an existing symlink")
	}
	got, err := os.Readlink(link)
	if err != nil || got != newTarget {
		t.Fatalf("expected symlink -> %q, got %q (err=%v)", newTarget, got, err)
	}
}

func TestFile_LinkRequiresSrc(t *testing.T) {
	f := NewFile()
	if _, err := f.Run(context.Background(), map[string]any{"path": "/tmp/x", "state": "link"}, false); err == nil {
		t.Fatal("expected error when state=link is missing 'src'")
	}
}

func TestFile_LinkRejectsExistingNonSymlink(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "plain-file")
	if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	f := NewFile()
	if _, err := f.Run(context.Background(), map[string]any{"path": path, "src": "/whatever", "state": "link"}, false); err == nil {
		t.Fatal("expected error when path exists and is not already a symlink")
	}
}

func TestFile_LinkOwnerUsesLchownNotChown(t *testing.T) {
	// A non-root test environment can't chown to another user, but it can
	// still prove the link-vs-target distinction: setting owner (to the
	// only uid actually permitted, our own) on a symlink must not touch
	// the target directory's own ownership metadata at all.
	dir := t.TempDir()
	target := filepath.Join(dir, "real-target")
	link := filepath.Join(dir, "the-link")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}

	f := NewFile()
	if _, err := f.Run(context.Background(), map[string]any{
		"path": link, "src": target, "state": "link", "owner": strconv.Itoa(os.Getuid()),
	}, false); err != nil {
		t.Fatalf("Run: %v", err)
	}

	after, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}
	beforeSt, beforeOK := before.Sys().(*syscall.Stat_t)
	afterSt, afterOK := after.Sys().(*syscall.Stat_t)
	if !beforeOK || !afterOK || beforeSt.Uid != afterSt.Uid || beforeSt.Gid != afterSt.Gid {
		t.Error("chowning the symlink must not change the target directory's own owner/group")
	}
}
