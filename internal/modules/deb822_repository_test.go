package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDeb822Repository_CreatesStanza(t *testing.T) {
	dir := t.TempDir()
	d := &Deb822Repository{SourcesDir: dir}
	res, err := d.Run(context.Background(), map[string]any{
		"name":       "myrepo",
		"uris":       []string{"https://example.com/repo"},
		"suites":     []string{"stable"},
		"components": []string{"main"},
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true creating a new stanza")
	}
	got, err := os.ReadFile(filepath.Join(dir, "myrepo.sources"))
	if err != nil {
		t.Fatalf("reading created file: %v", err)
	}
	for _, want := range []string{"Types: deb", "URIs: https://example.com/repo", "Suites: stable", "Components: main"} {
		if !strings.Contains(string(got), want) {
			t.Errorf("content missing %q, got %q", want, got)
		}
	}
}

func TestDeb822Repository_IdempotentWhenAlreadyMatching(t *testing.T) {
	dir := t.TempDir()
	d := &Deb822Repository{SourcesDir: dir}
	args := map[string]any{"name": "myrepo", "uris": []string{"https://example.com"}, "suites": []string{"stable"}}
	if _, err := d.Run(context.Background(), args, false); err != nil {
		t.Fatal(err)
	}
	res, err := d.Run(context.Background(), args, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when stanza already matches")
	}
}

func TestDeb822Repository_UpdatesWhenDifferent(t *testing.T) {
	dir := t.TempDir()
	d := &Deb822Repository{SourcesDir: dir}
	if _, err := d.Run(context.Background(), map[string]any{
		"name": "myrepo", "uris": []string{"https://a.example.com"}, "suites": []string{"stable"},
	}, false); err != nil {
		t.Fatal(err)
	}
	res, err := d.Run(context.Background(), map[string]any{
		"name": "myrepo", "uris": []string{"https://b.example.com"}, "suites": []string{"stable"},
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when URIs differ")
	}
	got, _ := os.ReadFile(filepath.Join(dir, "myrepo.sources"))
	if !strings.Contains(string(got), "https://b.example.com") || strings.Contains(string(got), "https://a.example.com") {
		t.Errorf("expected updated URI, got %q", got)
	}
}

func TestDeb822Repository_SignedByIncluded(t *testing.T) {
	dir := t.TempDir()
	d := &Deb822Repository{SourcesDir: dir}
	_, err := d.Run(context.Background(), map[string]any{
		"name": "myrepo", "uris": []string{"https://example.com"}, "suites": []string{"stable"},
		"signed_by": "/etc/apt/keyrings/myrepo.gpg",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "myrepo.sources"))
	if !strings.Contains(string(got), "Signed-By: /etc/apt/keyrings/myrepo.gpg") {
		t.Errorf("expected Signed-By field, got %q", got)
	}
}

func TestDeb822Repository_AbsentRemovesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "myrepo.sources")
	if err := os.WriteFile(path, []byte("Types: deb\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	d := &Deb822Repository{SourcesDir: dir}
	res, err := d.Run(context.Background(), map[string]any{"name": "myrepo", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing an existing file")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("expected file to be removed")
	}
}

func TestDeb822Repository_AbsentIdempotentWhenMissing(t *testing.T) {
	dir := t.TempDir()
	d := &Deb822Repository{SourcesDir: dir}
	res, err := d.Run(context.Background(), map[string]any{"name": "ghost", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing a stanza that doesn't exist")
	}
}

func TestDeb822Repository_MissingUrisErrors(t *testing.T) {
	d := &Deb822Repository{SourcesDir: t.TempDir()}
	_, err := d.Run(context.Background(), map[string]any{"name": "myrepo", "suites": []string{"stable"}}, false)
	if err == nil {
		t.Fatal("expected error when uris is missing for state=present")
	}
}

func TestDeb822Repository_MissingSuitesErrors(t *testing.T) {
	d := &Deb822Repository{SourcesDir: t.TempDir()}
	_, err := d.Run(context.Background(), map[string]any{"name": "myrepo", "uris": []string{"https://example.com"}}, false)
	if err == nil {
		t.Fatal("expected error when suites is missing for state=present")
	}
}

func TestDeb822Repository_PathTraversalNameRejected(t *testing.T) {
	d := &Deb822Repository{SourcesDir: t.TempDir()}
	_, err := d.Run(context.Background(), map[string]any{
		"name": "../escape", "uris": []string{"https://example.com"}, "suites": []string{"stable"},
	}, false)
	if err == nil {
		t.Fatal("expected error for a path-traversal name")
	}
}

func TestDeb822Repository_DryRunDoesNotWrite(t *testing.T) {
	dir := t.TempDir()
	d := &Deb822Repository{SourcesDir: dir}
	res, err := d.Run(context.Background(), map[string]any{
		"name": "myrepo", "uris": []string{"https://example.com"}, "suites": []string{"stable"}, "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(filepath.Join(dir, "myrepo.sources")); !os.IsNotExist(err) {
		t.Error("expected no file created under dry_run")
	}
}
