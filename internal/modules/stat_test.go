package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestStat_ExistingFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "hello.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}

	s := NewStat()
	res, err := s.Run(context.Background(), map[string]any{"path": path}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["exists"] != true {
		t.Errorf("exists = %v, want true", data["exists"])
	}
	if data["size"] != int64(5) {
		t.Errorf("size = %v, want 5", data["size"])
	}
	if data["isdir"] != false || data["isreg"] != true {
		t.Errorf("unexpected type flags: %+v", data)
	}
}

func TestStat_NonexistentPath(t *testing.T) {
	s := NewStat()
	res, err := s.Run(context.Background(), map[string]any{"path": "/no/such/path/xyz"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["exists"] != false {
		t.Errorf("exists = %v, want false", data["exists"])
	}
}

func TestStat_Directory(t *testing.T) {
	dir := t.TempDir()
	s := NewStat()
	res, err := s.Run(context.Background(), map[string]any{"path": dir}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["isdir"] != true {
		t.Errorf("isdir = %v, want true", data["isdir"])
	}
}

func TestStat_MissingPathParam(t *testing.T) {
	s := NewStat()
	if _, err := s.Run(context.Background(), map[string]any{}, false); err == nil {
		t.Fatal("expected error for missing path parameter")
	}
}
