package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestReplace_ReplacesAllMatches(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hosts")
	if err := os.WriteFile(path, []byte("127.0.0.1 old-name\n192.168.1.1 old-name\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := NewReplace()
	res, err := r.Run(context.Background(), map[string]any{
		"path": path, "regexp": "old-name", "replace": "new-name",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	got, _ := os.ReadFile(path)
	want := "127.0.0.1 new-name\n192.168.1.1 new-name\n"
	if string(got) != want {
		t.Errorf("content = %q, want %q", got, want)
	}
}

func TestReplace_Idempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(path, []byte("a b c\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := NewReplace()
	if _, err := r.Run(context.Background(), map[string]any{"path": path, "regexp": "b", "replace": "x"}, false); err != nil {
		t.Fatal(err)
	}
	res, err := r.Run(context.Background(), map[string]any{"path": path, "regexp": "b", "replace": "x"}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when no more matches exist")
	}
}

func TestReplace_BackreferenceSupport(t *testing.T) {
	path := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(path, []byte("key=value\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := NewReplace()
	res, err := r.Run(context.Background(), map[string]any{
		"path": path, "regexp": `(\w+)=(\w+)`, "replace": "$2=$1",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	got, _ := os.ReadFile(path)
	if string(got) != "value=key\n" {
		t.Errorf("content = %q, want %q", got, "value=key\n")
	}
}

func TestReplace_DefaultReplaceDeletesMatches(t *testing.T) {
	path := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(path, []byte("remove-THIS-please\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := NewReplace()
	res, err := r.Run(context.Background(), map[string]any{"path": path, "regexp": "-THIS-"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	got, _ := os.ReadFile(path)
	if string(got) != "removeplease\n" {
		t.Errorf("content = %q, want %q", got, "removeplease\n")
	}
}

func TestReplace_InvalidRegexpRejected(t *testing.T) {
	r := NewReplace()
	_, err := r.Run(context.Background(), map[string]any{"path": "/tmp/x", "regexp": "("}, false)
	if err == nil {
		t.Fatal("expected error for invalid regexp")
	}
}

func TestReplace_MissingFileErrors(t *testing.T) {
	r := NewReplace()
	path := filepath.Join(t.TempDir(), "missing")
	_, err := r.Run(context.Background(), map[string]any{"path": path, "regexp": "x"}, false)
	if err == nil {
		t.Fatal("expected error when file does not exist")
	}
}

func TestReplace_DryRunDoesNotWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(path, []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := NewReplace()
	res, err := r.Run(context.Background(), map[string]any{"path": path, "regexp": "a", "replace": "b", "dry_run": true}, false)
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
