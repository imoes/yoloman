package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTempfile_CreatesFile(t *testing.T) {
	dir := t.TempDir()
	tf := NewTempfile()
	res, err := tf.Run(context.Background(), map[string]any{"path": dir}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	path := res.Data.(map[string]any)["path"].(string)
	if filepath.Dir(path) != dir {
		t.Errorf("expected file under %q, got %q", dir, path)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("expected created file to exist: %v", err)
	}
}

func TestTempfile_CreatesDirectory(t *testing.T) {
	dir := t.TempDir()
	tf := NewTempfile()
	res, err := tf.Run(context.Background(), map[string]any{"path": dir, "state": "directory"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	path := res.Data.(map[string]any)["path"].(string)
	fi, err := os.Stat(path)
	if err != nil || !fi.IsDir() {
		t.Errorf("expected created directory to exist, got err=%v isDir=%v", err, fi != nil && fi.IsDir())
	}
}

func TestTempfile_PrefixSuffixApplied(t *testing.T) {
	dir := t.TempDir()
	tf := NewTempfile()
	res, err := tf.Run(context.Background(), map[string]any{"path": dir, "prefix": "myapp-", "suffix": ".conf"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	path := res.Data.(map[string]any)["path"].(string)
	base := filepath.Base(path)
	if !strings.HasPrefix(base, "myapp-") || !strings.HasSuffix(base, ".conf") {
		t.Errorf("expected prefix/suffix applied, got %q", base)
	}
}

func TestTempfile_EachCallIsUnique(t *testing.T) {
	dir := t.TempDir()
	tf := NewTempfile()
	res1, err := tf.Run(context.Background(), map[string]any{"path": dir}, false)
	if err != nil {
		t.Fatal(err)
	}
	res2, err := tf.Run(context.Background(), map[string]any{"path": dir}, false)
	if err != nil {
		t.Fatal(err)
	}
	p1 := res1.Data.(map[string]any)["path"].(string)
	p2 := res2.Data.(map[string]any)["path"].(string)
	if p1 == p2 {
		t.Errorf("expected two distinct paths, got the same %q both times", p1)
	}
	if !res1.Changed || !res2.Changed {
		t.Error("expected changed=true on every call, not idempotent by nature")
	}
}

func TestTempfile_InvalidState(t *testing.T) {
	tf := NewTempfile()
	_, err := tf.Run(context.Background(), map[string]any{"state": "bogus"}, false)
	if err == nil {
		t.Fatal("expected error for invalid state")
	}
}

func TestTempfile_DryRunDoesNotCreate(t *testing.T) {
	dir := t.TempDir()
	tf := NewTempfile()
	res, err := tf.Run(context.Background(), map[string]any{"path": dir, "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Errorf("expected no files created under dry_run, found %d", len(entries))
	}
}
