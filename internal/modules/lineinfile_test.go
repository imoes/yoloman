package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLineInFile_AppendsWhenAbsent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("existing=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l := NewLineInFile()

	res, err := l.Run(context.Background(), map[string]any{"path": path, "line": "new=2"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true appending new line")
	}
	got, _ := os.ReadFile(path)
	if !strings.Contains(string(got), "new=2") {
		t.Errorf("expected appended line, got %q", got)
	}
}

func TestLineInFile_IdempotentWhenLinePresent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("existing=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l := NewLineInFile()
	res, err := l.Run(context.Background(), map[string]any{"path": path, "line": "existing=1"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when line already present")
	}
}

func TestLineInFile_RegexpReplacesLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("port=8080\nother=x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l := NewLineInFile()
	res, err := l.Run(context.Background(), map[string]any{
		"path": path, "regexp": "^port=", "line": "port=9090",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true replacing matching line")
	}
	got, _ := os.ReadFile(path)
	if strings.Contains(string(got), "port=8080") || !strings.Contains(string(got), "port=9090") {
		t.Errorf("expected port=9090 to replace port=8080, got %q", got)
	}
	if !strings.Contains(string(got), "other=x") {
		t.Errorf("expected unrelated line preserved, got %q", got)
	}

	res2, err := l.Run(context.Background(), map[string]any{
		"path": path, "regexp": "^port=", "line": "port=9090",
	}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res2.Changed {
		t.Error("expected changed=false on idempotent 2nd run")
	}
}

func TestLineInFile_AbsentRemovesMatchingLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("keep=1\nremove=me\nkeep=2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l := NewLineInFile()
	res, err := l.Run(context.Background(), map[string]any{
		"path": path, "state": "absent", "regexp": "^remove=",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing matching line")
	}
	got, _ := os.ReadFile(path)
	if strings.Contains(string(got), "remove=me") {
		t.Errorf("expected line removed, got %q", got)
	}
	if !strings.Contains(string(got), "keep=1") || !strings.Contains(string(got), "keep=2") {
		t.Errorf("expected other lines preserved, got %q", got)
	}
}

func TestLineInFile_CreateMissingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "new-conf")
	l := NewLineInFile()
	res, err := l.Run(context.Background(), map[string]any{
		"path": path, "line": "hello=1", "create": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true creating file with line")
	}
	got, _ := os.ReadFile(path)
	if string(got) != "hello=1\n" {
		t.Errorf("content = %q, want %q", got, "hello=1\n")
	}
}

func TestLineInFile_MissingFileWithoutCreateErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing")
	l := NewLineInFile()
	if _, err := l.Run(context.Background(), map[string]any{"path": path, "line": "x"}, false); err == nil {
		t.Fatal("expected error when file missing and create=false")
	}
}

func TestLineInFile_DryRunDoesNotWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conf")
	if err := os.WriteFile(path, []byte("a=1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	l := NewLineInFile()
	res, err := l.Run(context.Background(), map[string]any{"path": path, "line": "b=2", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	got, _ := os.ReadFile(path)
	if string(got) != "a=1\n" {
		t.Errorf("expected file unchanged under dry_run, got %q", got)
	}
}
