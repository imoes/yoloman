package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBlockInFile_AppendsWhenMarkersAbsent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("existing=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	b := NewBlockInFile()
	res, err := b.Run(context.Background(), map[string]any{"path": path, "block": "line1\nline2"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true appending new block")
	}
	got, _ := os.ReadFile(path)
	want := "existing=1\n# BEGIN ANSIBLE MANAGED BLOCK\nline1\nline2\n# END ANSIBLE MANAGED BLOCK\n"
	if string(got) != want {
		t.Errorf("content = %q, want %q", got, want)
	}
}

func TestBlockInFile_IdempotentWhenBlockMatches(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	b := NewBlockInFile()
	if _, err := b.Run(context.Background(), map[string]any{"path": path, "block": "hello", "create": true}, false); err != nil {
		t.Fatal(err)
	}
	res, err := b.Run(context.Background(), map[string]any{"path": path, "block": "hello", "create": true}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when block content already matches")
	}
}

func TestBlockInFile_ReplacesExistingBlockInPlace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("before\n# BEGIN ANSIBLE MANAGED BLOCK\nold\n# END ANSIBLE MANAGED BLOCK\nafter\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	b := NewBlockInFile()
	res, err := b.Run(context.Background(), map[string]any{"path": path, "block": "new"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true replacing block content")
	}
	got, _ := os.ReadFile(path)
	want := "before\n# BEGIN ANSIBLE MANAGED BLOCK\nnew\n# END ANSIBLE MANAGED BLOCK\nafter\n"
	if string(got) != want {
		t.Errorf("content = %q, want %q", got, want)
	}
}

func TestBlockInFile_AbsentRemovesBlock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("before\n# BEGIN ANSIBLE MANAGED BLOCK\nstuff\n# END ANSIBLE MANAGED BLOCK\nafter\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	b := NewBlockInFile()
	res, err := b.Run(context.Background(), map[string]any{"path": path, "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing block")
	}
	got, _ := os.ReadFile(path)
	if strings.Contains(string(got), "stuff") || strings.Contains(string(got), "MANAGED BLOCK") {
		t.Errorf("expected block removed, got %q", got)
	}
	if !strings.Contains(string(got), "before") || !strings.Contains(string(got), "after") {
		t.Errorf("expected surrounding content preserved, got %q", got)
	}
}

func TestBlockInFile_AbsentWithNoBlockIsNoop(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("just some content\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	b := NewBlockInFile()
	res, err := b.Run(context.Background(), map[string]any{"path": path, "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when there is no block to remove")
	}
}

func TestBlockInFile_MissingFileWithoutCreateErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing")
	b := NewBlockInFile()
	if _, err := b.Run(context.Background(), map[string]any{"path": path, "block": "x"}, false); err == nil {
		t.Fatal("expected error when file missing and create=false")
	}
}

func TestBlockInFile_DryRunDoesNotWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	b := NewBlockInFile()
	res, err := b.Run(context.Background(), map[string]any{"path": path, "block": "x", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	got, _ := os.ReadFile(path)
	if string(got) != "a\n" {
		t.Errorf("expected file unchanged under dry_run, got %q", got)
	}
}

func TestBlockInFile_InvalidMarkerRejected(t *testing.T) {
	b := NewBlockInFile()
	_, err := b.Run(context.Background(), map[string]any{
		"path": "/tmp/x", "block": "x", "marker": "no placeholder here",
	}, false)
	if err == nil {
		t.Fatal("expected error for a marker template missing {mark}")
	}
}
