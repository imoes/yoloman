package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func logData(t *testing.T, res Result) map[string]any {
	t.Helper()
	d, ok := res.Data.(map[string]any)
	if !ok {
		t.Fatalf("Data is not a map: %T", res.Data)
	}
	return d
}

func TestLogFilesListAndRead(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "app.log"), []byte("l1\nl2\nl3\nl4\nl5\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "wtmp"), []byte("binary"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := &LogFiles{Roots: []string{root}}

	// list: finds app.log, skips the wtmp binary db.
	res, err := m.Run(context.Background(), map[string]any{"state": "list"}, false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	files, _ := logData(t, res)["files"].([]struct {
		Path     string `json:"path"`
		Size     int64  `json:"size"`
		Modified int64  `json:"modified"`
	})
	_ = files // shape is an anonymous struct; assert via count instead
	if logData(t, res)["count"].(int) != 1 {
		t.Fatalf("expected 1 listed file (wtmp skipped), got %v", logData(t, res)["count"])
	}

	// read: tail last 2 lines.
	res, err = m.Run(context.Background(), map[string]any{"state": "read", "path": filepath.Join(root, "app.log"), "lines": 2}, false)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	lines, _ := logData(t, res)["lines"].([]string)
	if len(lines) != 2 || lines[0] != "l4" || lines[1] != "l5" {
		t.Fatalf("expected last 2 lines [l4 l5], got %v", lines)
	}
}

func TestLogFilesGrep(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "s.log"), []byte("info ok\nERROR boom\ninfo fine\nERROR again\n"), 0o644)
	m := &LogFiles{Roots: []string{root}}
	res, err := m.Run(context.Background(), map[string]any{"state": "read", "path": filepath.Join(root, "s.log"), "grep": "ERROR"}, false)
	if err != nil {
		t.Fatal(err)
	}
	lines, _ := logData(t, res)["lines"].([]string)
	if len(lines) != 2 || lines[0] != "ERROR boom" || lines[1] != "ERROR again" {
		t.Fatalf("grep ERROR expected 2 lines, got %v", lines)
	}
}

func TestLogFilesPathJail(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "ok.log"), []byte("x\n"), 0o644)
	// A secret outside the root must never be readable.
	secret := filepath.Join(t.TempDir(), "secret")
	os.WriteFile(secret, []byte("top-secret\n"), 0o600)
	m := &LogFiles{Roots: []string{root}}

	if _, err := m.Run(context.Background(), map[string]any{"state": "read", "path": secret}, false); err == nil {
		t.Fatal("expected path outside roots to be rejected")
	}
	// Traversal attempt.
	if _, err := m.Run(context.Background(), map[string]any{"state": "read", "path": filepath.Join(root, "..", filepath.Base(filepath.Dir(secret)), "secret")}, false); err == nil {
		t.Fatal("expected traversal outside roots to be rejected")
	}
}
