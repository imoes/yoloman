package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func writeFragment(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestAssemble_ConcatenatesInSortedOrder(t *testing.T) {
	src := t.TempDir()
	writeFragment(t, src, "20-second.conf", "second\n")
	writeFragment(t, src, "10-first.conf", "first\n")
	writeFragment(t, src, "30-third.conf", "third\n")

	dest := filepath.Join(t.TempDir(), "assembled.conf")
	a := NewAssemble()
	res, err := a.Run(context.Background(), map[string]any{"src": src, "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true on first assembly")
	}
	got, _ := os.ReadFile(dest)
	want := "first\nsecond\nthird\n"
	if string(got) != want {
		t.Errorf("content = %q, want %q", got, want)
	}
}

func TestAssemble_RegexpFiltersFragments(t *testing.T) {
	src := t.TempDir()
	writeFragment(t, src, "a.conf", "A\n")
	writeFragment(t, src, "b.txt", "B\n")

	dest := filepath.Join(t.TempDir(), "assembled.conf")
	a := NewAssemble()
	_, err := a.Run(context.Background(), map[string]any{"src": src, "dest": dest, "regexp": `\.conf$`}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "A\n" {
		t.Errorf("content = %q, want %q (b.txt should be filtered out)", got, "A\n")
	}
}

func TestAssemble_DelimiterInsertedBetweenFragments(t *testing.T) {
	src := t.TempDir()
	writeFragment(t, src, "1.conf", "one")
	writeFragment(t, src, "2.conf", "two")

	dest := filepath.Join(t.TempDir(), "assembled.conf")
	a := NewAssemble()
	_, err := a.Run(context.Background(), map[string]any{"src": src, "dest": dest, "delimiter": "---\n"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "one---\ntwo" {
		t.Errorf("content = %q, want %q", got, "one---\ntwo")
	}
}

func TestAssemble_Idempotent(t *testing.T) {
	src := t.TempDir()
	writeFragment(t, src, "1.conf", "content\n")

	dest := filepath.Join(t.TempDir(), "assembled.conf")
	a := NewAssemble()
	if _, err := a.Run(context.Background(), map[string]any{"src": src, "dest": dest}, false); err != nil {
		t.Fatal(err)
	}
	res, err := a.Run(context.Background(), map[string]any{"src": src, "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when assembled content already matches dest")
	}
}

func TestAssemble_MissingSrcErrors(t *testing.T) {
	a := NewAssemble()
	_, err := a.Run(context.Background(), map[string]any{
		"src": filepath.Join(t.TempDir(), "does-not-exist"), "dest": filepath.Join(t.TempDir(), "d"),
	}, false)
	if err == nil {
		t.Fatal("expected error when src directory does not exist")
	}
}

func TestAssemble_DryRunDoesNotWrite(t *testing.T) {
	src := t.TempDir()
	writeFragment(t, src, "1.conf", "x\n")
	dest := filepath.Join(t.TempDir(), "assembled.conf")

	a := NewAssemble()
	res, err := a.Run(context.Background(), map[string]any{"src": src, "dest": dest, "dry_run": true}, false)
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
