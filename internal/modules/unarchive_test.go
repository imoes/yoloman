package modules

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"context"
	"os"
	"path/filepath"
	"testing"
)

func writeZip(t *testing.T, path string, files map[string]string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zw := zip.NewWriter(f)
	for name, content := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
}

func writeTarGz(t *testing.T, path string, files map[string]string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		hdr := &tar.Header{Name: name, Mode: 0o644, Size: int64(len(content))}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestUnarchive_ExtractsZip(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "archive.zip")
	writeZip(t, src, map[string]string{"hello.txt": "world", "sub/nested.txt": "nested content"})

	dest := filepath.Join(dir, "out")
	u := NewUnarchive()
	res, err := u.Run(context.Background(), map[string]any{"src": src, "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	got, err := os.ReadFile(filepath.Join(dest, "hello.txt"))
	if err != nil {
		t.Fatalf("reading extracted file: %v", err)
	}
	if string(got) != "world" {
		t.Errorf("content = %q, want world", got)
	}
	got2, err := os.ReadFile(filepath.Join(dest, "sub", "nested.txt"))
	if err != nil {
		t.Fatalf("reading nested extracted file: %v", err)
	}
	if string(got2) != "nested content" {
		t.Errorf("nested content = %q", got2)
	}
}

func TestUnarchive_ExtractsTarGz(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "archive.tar.gz")
	writeTarGz(t, src, map[string]string{"file.txt": "tar content"})

	dest := filepath.Join(dir, "out")
	u := NewUnarchive()
	res, err := u.Run(context.Background(), map[string]any{"src": src, "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	got, err := os.ReadFile(filepath.Join(dest, "file.txt"))
	if err != nil {
		t.Fatalf("reading extracted file: %v", err)
	}
	if string(got) != "tar content" {
		t.Errorf("content = %q", got)
	}
}

func TestUnarchive_CreatesSkipsWhenPathExists(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "archive.zip")
	writeZip(t, src, map[string]string{"file.txt": "content"})

	marker := filepath.Join(dir, "already-there")
	if err := os.WriteFile(marker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	dest := filepath.Join(dir, "out")
	u := NewUnarchive()
	res, err := u.Run(context.Background(), map[string]any{"src": src, "dest": dest, "creates": marker}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when creates path already exists")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Error("expected dest to not be created when creates path already exists")
	}
}

func TestUnarchive_DryRunDoesNotExtract(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "archive.zip")
	writeZip(t, src, map[string]string{"file.txt": "content"})

	dest := filepath.Join(dir, "out")
	u := NewUnarchive()
	res, err := u.Run(context.Background(), map[string]any{"src": src, "dest": dest, "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Error("expected dry_run to not actually extract")
	}
}

func TestUnarchive_UnrecognizedExtensionErrors(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "archive.rar")
	if err := os.WriteFile(src, []byte("not really a rar"), 0o644); err != nil {
		t.Fatal(err)
	}
	u := NewUnarchive()
	_, err := u.Run(context.Background(), map[string]any{"src": src, "dest": filepath.Join(dir, "out")}, false)
	if err == nil {
		t.Fatal("expected error for unrecognized archive extension")
	}
}

func TestUnarchive_PathTraversalRejected(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "evil.zip")
	f, err := os.Create(src)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	w, err := zw.Create("../escaped.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte("pwned")); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()

	dest := filepath.Join(dir, "out")
	u := NewUnarchive()
	_, err = u.Run(context.Background(), map[string]any{"src": src, "dest": dest}, false)
	if err == nil {
		t.Fatal("expected error for a path-traversal archive member")
	}
	if _, statErr := os.Stat(filepath.Join(dir, "escaped.txt")); !os.IsNotExist(statErr) {
		t.Error("path traversal member must not be written outside dest")
	}
}

func TestUnarchive_MissingRequiredParams(t *testing.T) {
	u := NewUnarchive()
	if _, err := u.Run(context.Background(), map[string]any{"dest": "/tmp/x"}, false); err == nil {
		t.Error("expected error when src is missing")
	}
	if _, err := u.Run(context.Background(), map[string]any{"src": "/tmp/x.zip"}, false); err == nil {
		t.Error("expected error when dest is missing")
	}
}
