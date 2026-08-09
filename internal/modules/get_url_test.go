package modules

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func fakeHTTPGet(content string) HTTPGetFunc {
	return func(url string) ([]byte, error) { return []byte(content), nil }
}

func TestGetURL_DownloadsWhenDestMissing(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "file.txt")
	g := &GetURL{HTTPGet: fakeHTTPGet("hello world")}
	res, err := g.Run(context.Background(), map[string]any{"url": "https://example.com/f", "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true downloading a missing file")
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "hello world" {
		t.Errorf("content = %q", got)
	}
}

func TestGetURL_SkipsWhenDestExistsNoForceNoChecksum(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "file.txt")
	if err := os.WriteFile(dest, []byte("existing"), 0o644); err != nil {
		t.Fatal(err)
	}
	called := false
	g := &GetURL{HTTPGet: func(url string) ([]byte, error) { called = true; return []byte("new"), nil }}
	res, err := g.Run(context.Background(), map[string]any{"url": "https://example.com/f", "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when dest exists and neither force nor checksum given")
	}
	if called {
		t.Error("expected no download attempt")
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "existing" {
		t.Error("expected existing file left untouched")
	}
}

func TestGetURL_ForceAlwaysRedownloads(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "file.txt")
	if err := os.WriteFile(dest, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	g := &GetURL{HTTPGet: fakeHTTPGet("new content")}
	res, err := g.Run(context.Background(), map[string]any{"url": "https://example.com/f", "dest": dest, "force": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true with force=true")
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "new content" {
		t.Errorf("content = %q", got)
	}
}

func TestGetURL_ChecksumMismatchTriggersRedownload(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "file.txt")
	if err := os.WriteFile(dest, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	newContent := "correct content"
	sum := sha256.Sum256([]byte(newContent))
	checksum := "sha256:" + hex.EncodeToString(sum[:])

	g := &GetURL{HTTPGet: fakeHTTPGet(newContent)}
	res, err := g.Run(context.Background(), map[string]any{
		"url": "https://example.com/f", "dest": dest, "checksum": checksum,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when existing file's checksum doesn't match")
	}
	got, _ := os.ReadFile(dest)
	if string(got) != newContent {
		t.Errorf("content = %q", got)
	}
}

func TestGetURL_ChecksumMatchSkipsDownload(t *testing.T) {
	content := "same content"
	sum := sha256.Sum256([]byte(content))
	checksum := "sha256:" + hex.EncodeToString(sum[:])
	dest := filepath.Join(t.TempDir(), "file.txt")
	if err := os.WriteFile(dest, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	called := false
	g := &GetURL{HTTPGet: func(url string) ([]byte, error) { called = true; return nil, nil }}
	res, err := g.Run(context.Background(), map[string]any{
		"url": "https://example.com/f", "dest": dest, "checksum": checksum,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when checksum already matches")
	}
	if called {
		t.Error("expected no download when checksum already matches")
	}
}

func TestGetURL_DownloadedChecksumMismatchErrors(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "file.txt")
	g := &GetURL{HTTPGet: fakeHTTPGet("actual content")}
	_, err := g.Run(context.Background(), map[string]any{
		"url": "https://example.com/f", "dest": dest, "checksum": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
	}, false)
	if err == nil {
		t.Fatal("expected error when downloaded content doesn't match the given checksum")
	}
	if _, statErr := os.Stat(dest); statErr == nil {
		t.Error("expected dest to not be written when checksum verification fails")
	}
}

func TestGetURL_InvalidChecksumFormatRejected(t *testing.T) {
	g := &GetURL{HTTPGet: fakeHTTPGet("x")}
	_, err := g.Run(context.Background(), map[string]any{
		"url": "https://example.com/f", "dest": "/tmp/x", "checksum": "notarealformat",
	}, false)
	if err == nil {
		t.Fatal("expected error for a malformed checksum parameter")
	}
}

func TestGetURL_HTTPFailurePropagatesError(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "file.txt")
	g := &GetURL{HTTPGet: func(url string) ([]byte, error) { return nil, os.ErrDeadlineExceeded }}
	_, err := g.Run(context.Background(), map[string]any{"url": "https://example.com/f", "dest": dest}, false)
	if err == nil {
		t.Fatal("expected error when the HTTP request fails")
	}
}

func TestGetURL_DryRunDoesNotWrite(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "file.txt")
	g := &GetURL{HTTPGet: fakeHTTPGet("content")}
	res, err := g.Run(context.Background(), map[string]any{"url": "https://example.com/f", "dest": dest, "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Error("expected no file created under dry_run")
	}
}
