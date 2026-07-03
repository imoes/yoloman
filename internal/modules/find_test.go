package modules

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// layout:
//
//	root/
//	  a.txt
//	  b.log
//	  sub/
//	    c.txt
func newFindTestTree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "a.txt"), []byte("a"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "b.log"), []byte("b"), 0o644); err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(root, "sub")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "c.txt"), []byte("c"), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func matchPaths(t *testing.T, res Result) []string {
	t.Helper()
	items := res.Data.([]map[string]any)
	var paths []string
	for _, it := range items {
		paths = append(paths, filepath.Base(it["path"].(string)))
	}
	sort.Strings(paths)
	return paths
}

func TestFind_NonRecursive(t *testing.T) {
	root := newFindTestTree(t)
	f := NewFind()
	res, err := f.Run(context.Background(), map[string]any{"paths": []string{root}}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got := matchPaths(t, res)
	want := []string{"a.txt", "b.log", "sub"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("got %v, want %v", got, want)
			break
		}
	}
}

func TestFind_Recursive(t *testing.T) {
	root := newFindTestTree(t)
	f := NewFind()
	res, err := f.Run(context.Background(), map[string]any{
		"paths":   []string{root},
		"recurse": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got := matchPaths(t, res)
	want := []string{"a.txt", "b.log", "c.txt", "sub"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestFind_PatternFilter(t *testing.T) {
	root := newFindTestTree(t)
	f := NewFind()
	res, err := f.Run(context.Background(), map[string]any{
		"paths":   []string{root},
		"recurse": true,
		"pattern": "*.txt",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got := matchPaths(t, res)
	want := []string{"a.txt", "c.txt"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestFind_FileTypeFilter(t *testing.T) {
	root := newFindTestTree(t)
	f := NewFind()
	res, err := f.Run(context.Background(), map[string]any{
		"paths":     []string{root},
		"file_type": "directory",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got := matchPaths(t, res)
	if len(got) != 1 || got[0] != "sub" {
		t.Errorf("got %v, want [sub]", got)
	}
}

func TestFind_InvalidFileType(t *testing.T) {
	root := newFindTestTree(t)
	f := NewFind()
	if _, err := f.Run(context.Background(), map[string]any{
		"paths":     []string{root},
		"file_type": "bogus",
	}, false); err == nil {
		t.Fatal("expected error for invalid file_type")
	}
}

func TestFind_MissingPaths(t *testing.T) {
	f := NewFind()
	if _, err := f.Run(context.Background(), map[string]any{}, false); err == nil {
		t.Fatal("expected error for missing paths parameter")
	}
}
