package modules

import (
	"context"
	"os"
	"path/filepath"
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
