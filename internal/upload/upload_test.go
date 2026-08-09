package upload

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateFilename(t *testing.T) {
	cases := []struct {
		name    string
		wantErr bool
	}{
		{"kernel-package.deb", false},
		{"nginx.conf", false},
		{"", true},
		{"../etc/passwd", true},
		{"a/b", true},
		{`a\b`, true},
		{".", true},
		{"..", true},
	}
	for _, c := range cases {
		err := ValidateFilename(c.name)
		if (err != nil) != c.wantErr {
			t.Errorf("ValidateFilename(%q) error = %v, wantErr %v", c.name, err, c.wantErr)
		}
	}
}

func TestWriteStaged_Success(t *testing.T) {
	dir := t.TempDir()
	content := []byte("hello, staged world")
	n, err := WriteStaged(dir, "greeting.txt", bytes.NewReader(content), 1024)
	if err != nil {
		t.Fatalf("WriteStaged: %v", err)
	}
	if n != int64(len(content)) {
		t.Errorf("n = %d, want %d", n, len(content))
	}
	got, err := os.ReadFile(filepath.Join(dir, "greeting.txt"))
	if err != nil {
		t.Fatalf("reading staged file: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("staged content = %q, want %q", got, content)
	}
}

func TestWriteStaged_CreatesDirIfMissing(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "nested", "uploads")
	_, err := WriteStaged(dir, "f.txt", strings.NewReader("x"), 100)
	if err != nil {
		t.Fatalf("WriteStaged: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "f.txt")); err != nil {
		t.Fatalf("expected staged file to exist: %v", err)
	}
}

func TestWriteStaged_OverwriteIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	if _, err := WriteStaged(dir, "f.txt", strings.NewReader("version 1"), 100); err != nil {
		t.Fatalf("first WriteStaged: %v", err)
	}
	if _, err := WriteStaged(dir, "f.txt", strings.NewReader("version 2, longer content"), 100); err != nil {
		t.Fatalf("second WriteStaged: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "f.txt"))
	if err != nil {
		t.Fatalf("reading staged file: %v", err)
	}
	if string(got) != "version 2, longer content" {
		t.Errorf("expected overwrite to win, got %q", got)
	}

	// No leftover temp files from either upload.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 1 {
		names := make([]string, len(entries))
		for i, e := range entries {
			names[i] = e.Name()
		}
		t.Errorf("expected exactly 1 file in staging dir, got %v", names)
	}
}

func TestWriteStaged_RejectsPathTraversal(t *testing.T) {
	dir := t.TempDir()
	_, err := WriteStaged(dir, "../escape.txt", strings.NewReader("x"), 100)
	if err == nil {
		t.Fatal("expected error for path-traversal filename")
	}
	if _, statErr := os.Stat(filepath.Join(filepath.Dir(dir), "escape.txt")); statErr == nil {
		t.Fatal("file must not have been written outside the staging directory")
	}
}

func TestWriteStaged_EnforcesSizeLimit(t *testing.T) {
	dir := t.TempDir()
	content := strings.Repeat("x", 101)
	_, err := WriteStaged(dir, "toobig.bin", strings.NewReader(content), 100)
	if err == nil {
		t.Fatal("expected error for content exceeding max size")
	}

	// No partial file should remain in the staging directory.
	entries, readErr := os.ReadDir(dir)
	if readErr != nil {
		t.Fatalf("ReadDir: %v", readErr)
	}
	if len(entries) != 0 {
		t.Errorf("expected no leftover files after rejected oversized upload, got %d", len(entries))
	}
}

func TestWriteStaged_ExactlyAtLimitSucceeds(t *testing.T) {
	dir := t.TempDir()
	content := strings.Repeat("x", 100)
	n, err := WriteStaged(dir, "exact.bin", strings.NewReader(content), 100)
	if err != nil {
		t.Fatalf("WriteStaged at exact limit: %v", err)
	}
	if n != 100 {
		t.Errorf("n = %d, want 100", n)
	}
}

// erroringReader fails after producing n bytes, simulating an interrupted
// transfer (client disconnect mid-upload).
type erroringReader struct {
	data []byte
	pos  int
}

func (r *erroringReader) Read(p []byte) (int, error) {
	if r.pos >= len(r.data) {
		return 0, io.ErrClosedPipe
	}
	n := copy(p, r.data[r.pos:])
	r.pos += n
	return n, nil
}

func TestWriteStaged_InterruptedTransferLeavesNoFile(t *testing.T) {
	dir := t.TempDir()
	_, err := WriteStaged(dir, "interrupted.bin", &erroringReader{data: []byte("partial")}, 1000)
	if err == nil {
		t.Fatal("expected error for interrupted transfer")
	}
	entries, readErr := os.ReadDir(dir)
	if readErr != nil {
		t.Fatalf("ReadDir: %v", readErr)
	}
	if len(entries) != 0 {
		t.Errorf("expected no leftover (partial) files after interrupted transfer, got %d", len(entries))
	}
}
