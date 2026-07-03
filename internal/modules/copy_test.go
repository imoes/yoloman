package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestCopy_ContentWritesThenIdempotent(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "motd")
	c := NewCopy()

	res, err := c.Run(context.Background(), map[string]any{"dest": dest, "content": "hello\n"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true on first write")
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "hello\n" {
		t.Errorf("content = %q, want %q", got, "hello\n")
	}

	res2, err := c.Run(context.Background(), map[string]any{"dest": dest, "content": "hello\n"}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res2.Changed {
		t.Error("expected changed=false when content already matches")
	}
}

func TestCopy_ContentChangeOverwrites(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "motd")
	c := NewCopy()
	if _, err := c.Run(context.Background(), map[string]any{"dest": dest, "content": "v1\n"}, false); err != nil {
		t.Fatal(err)
	}
	res, err := c.Run(context.Background(), map[string]any{"dest": dest, "content": "v2\n"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when content differs")
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "v2\n" {
		t.Errorf("content = %q, want %q", got, "v2\n")
	}
}

func TestCopy_DryRunDoesNotWrite(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "motd")
	c := NewCopy()
	res, err := c.Run(context.Background(), map[string]any{"dest": dest, "content": "hello\n", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Error("expected dest to NOT exist after dry_run")
	}
}

func TestCopy_FromSrc(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.txt")
	dest := filepath.Join(dir, "dest.txt")
	if err := os.WriteFile(src, []byte("source content"), 0o644); err != nil {
		t.Fatal(err)
	}
	c := NewCopy()
	res, err := c.Run(context.Background(), map[string]any{"dest": dest, "src": src}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "source content" {
		t.Errorf("content = %q, want %q", got, "source content")
	}
}

func TestCopy_BothContentAndSrcRejected(t *testing.T) {
	c := NewCopy()
	_, err := c.Run(context.Background(), map[string]any{
		"dest": "/tmp/x", "content": "a", "src": "/tmp/b",
	}, false)
	if err == nil {
		t.Fatal("expected error when both content and src are given")
	}
}

func TestCopy_NeitherContentNorSrcRejected(t *testing.T) {
	c := NewCopy()
	if _, err := c.Run(context.Background(), map[string]any{"dest": "/tmp/x"}, false); err == nil {
		t.Fatal("expected error when neither content nor src is given")
	}
}

// TestCopy_MissingSrcPropagatesError guards the write-error-propagation
// contract: a src file that doesn't exist must surface as a Go error, not
// be silently treated as empty content.
func TestCopy_MissingSrcPropagatesError(t *testing.T) {
	c := NewCopy()
	dest := filepath.Join(t.TempDir(), "dest.txt")
	_, err := c.Run(context.Background(), map[string]any{
		"dest": dest, "src": filepath.Join(t.TempDir(), "does-not-exist.txt"),
	}, false)
	if err == nil {
		t.Fatal("expected error when src does not exist")
	}
	if _, statErr := os.Stat(dest); statErr == nil {
		t.Error("expected dest to not be created when src is missing")
	}
}

// TestCopy_UnwritableDestPropagatesError: a write failure (here, a dest
// path whose parent directory doesn't exist) must surface as an error.
func TestCopy_UnwritableDestPropagatesError(t *testing.T) {
	c := NewCopy()
	dest := filepath.Join(t.TempDir(), "no-such-parent-dir", "dest.txt")
	_, err := c.Run(context.Background(), map[string]any{"dest": dest, "content": "hello"}, false)
	if err == nil {
		t.Fatal("expected error when dest's parent directory does not exist")
	}
}
