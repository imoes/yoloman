package modules

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestFetch_ReturnsBase64Content(t *testing.T) {
	path := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(path, []byte("hello fetch"), 0o644); err != nil {
		t.Fatal(err)
	}
	f := NewFetch()
	res, err := f.Run(context.Background(), map[string]any{"src": path}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	got, err := base64.StdEncoding.DecodeString(data["content"].(string))
	if err != nil {
		t.Fatalf("decoding content: %v", err)
	}
	if string(got) != "hello fetch" {
		t.Errorf("content = %q, want %q", got, "hello fetch")
	}
}

func TestFetch_IsReadOnly(t *testing.T) {
	f := NewFetch()
	if f.Writes() {
		t.Error("expected fetch to be read-only, like slurp")
	}
}

func TestFetch_MissingFileErrors(t *testing.T) {
	f := NewFetch()
	_, err := f.Run(context.Background(), map[string]any{"src": filepath.Join(t.TempDir(), "missing")}, false)
	if err == nil {
		t.Fatal("expected error for a missing file")
	}
}
