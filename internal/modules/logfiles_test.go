package modules

import (
	"bytes"
	"compress/gzip"
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

func TestLogFilesGrepRegexAndInvert(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "s.log"),
		[]byte("info ok\nERROR code=500\nwarn slow\nERROR code=404\ndebug trace\n"), 0o644)
	m := &LogFiles{Roots: []string{root}}
	p := filepath.Join(root, "s.log")

	// regex=true: extended regexp (grep -E). "ERROR code=(500|404)" matches both errors.
	res, err := m.Run(context.Background(), map[string]any{
		"state": "read", "path": p, "grep": "ERROR code=(500|404)", "regex": true}, false)
	if err != nil {
		t.Fatal(err)
	}
	lines, _ := logData(t, res)["lines"].([]string)
	if len(lines) != 2 || lines[0] != "ERROR code=500" || lines[1] != "ERROR code=404" {
		t.Fatalf("regex expected 2 ERROR lines, got %v", lines)
	}

	// invert=true (grep -v): drop the ERROR lines, keep the other 3.
	res, err = m.Run(context.Background(), map[string]any{
		"state": "read", "path": p, "grep": "ERROR", "invert": true}, false)
	if err != nil {
		t.Fatal(err)
	}
	lines, _ = logData(t, res)["lines"].([]string)
	if len(lines) != 3 || lines[0] != "info ok" || lines[2] != "debug trace" {
		t.Fatalf("invert expected 3 non-ERROR lines, got %v", lines)
	}

	// regex + invert together: keep lines NOT matching the digit-code pattern.
	res, err = m.Run(context.Background(), map[string]any{
		"state": "read", "path": p, "grep": "code=[0-9]+", "regex": true, "invert": true}, false)
	if err != nil {
		t.Fatal(err)
	}
	lines, _ = logData(t, res)["lines"].([]string)
	if len(lines) != 3 {
		t.Fatalf("regex+invert expected 3 lines, got %v", lines)
	}

	// A malformed regex is a caller error, surfaced (not a silent empty result).
	if _, err := m.Run(context.Background(), map[string]any{
		"state": "read", "path": p, "grep": "ERROR code=(", "regex": true}, false); err == nil {
		t.Fatal("expected invalid regex to be rejected")
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

func TestLogFilesReadGzip(t *testing.T) {
	root := t.TempDir()
	// Write a gzip-compressed rotated log (syslog.1.gz-style).
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	if _, err := gz.Write([]byte("g1\ng2\ng3\ng4\ng5\n")); err != nil {
		t.Fatal(err)
	}
	gz.Close()
	p := filepath.Join(root, "syslog.1.gz")
	if err := os.WriteFile(p, b.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	m := &LogFiles{Roots: []string{root}}

	// read: the .gz must be transparently decompressed, then tailed by line.
	res, err := m.Run(context.Background(), map[string]any{"state": "read", "path": p, "lines": 2}, false)
	if err != nil {
		t.Fatalf("read gz: %v", err)
	}
	lines, _ := logData(t, res)["lines"].([]string)
	if len(lines) != 2 || lines[0] != "g4" || lines[1] != "g5" {
		t.Fatalf("expected decompressed last 2 lines [g4 g5], got %v", lines)
	}

	// grep works on the decompressed content too.
	res, err = m.Run(context.Background(), map[string]any{"state": "read", "path": p, "grep": "g3"}, false)
	if err != nil {
		t.Fatalf("read gz grep: %v", err)
	}
	lines, _ = logData(t, res)["lines"].([]string)
	if len(lines) != 1 || lines[0] != "g3" {
		t.Fatalf("expected [g3], got %v", lines)
	}
}

func TestLogFilesListHidesRotated(t *testing.T) {
	root := t.TempDir()
	for _, n := range []string{
		"syslog",                    // live — shown
		"mail.log",                  // live — shown
		"syslog.1.gz",               // compressed — hidden
		"alternatives.log.2.gz",     // compressed — hidden
		"mail.log-20260712",         // date-rotated — hidden
		"syslog-20260712.gz",        // date-rotated + compressed — hidden
	} {
		if err := os.WriteFile(filepath.Join(root, n), []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	m := &LogFiles{Roots: []string{root}}
	res, err := m.Run(context.Background(), map[string]any{"state": "list"}, false)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if got := logData(t, res)["count"].(int); got != 2 {
		t.Fatalf("expected 2 live logs listed (rotated/gz hidden), got %d", got)
	}
	if isRotatedLog("syslog") || !isRotatedLog("a.gz") || !isRotatedLog("mail.log-20260712") || !isRotatedLog("x-20260712.gz") {
		t.Fatal("isRotatedLog classification wrong")
	}
}
