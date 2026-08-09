package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestYumRepository_CreatesStanza(t *testing.T) {
	dir := t.TempDir()
	y := &YumRepository{ReposDir: dir}
	res, err := y.Run(context.Background(), map[string]any{
		"name": "myrepo", "description": "My Repo", "baseurl": "https://example.com/repo",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true creating a new stanza")
	}
	got, err := os.ReadFile(filepath.Join(dir, "myrepo.repo"))
	if err != nil {
		t.Fatalf("reading created file: %v", err)
	}
	for _, want := range []string{"[myrepo]", "name=My Repo", "baseurl=https://example.com/repo", "enabled=1", "gpgcheck=1"} {
		if !strings.Contains(string(got), want) {
			t.Errorf("content missing %q, got %q", want, got)
		}
	}
}

func TestYumRepository_DisabledAndNoGPGCheck(t *testing.T) {
	dir := t.TempDir()
	y := &YumRepository{ReposDir: dir}
	_, err := y.Run(context.Background(), map[string]any{
		"name": "myrepo", "baseurl": "https://example.com/repo", "enabled": false, "gpgcheck": false,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "myrepo.repo"))
	if !strings.Contains(string(got), "enabled=0") || !strings.Contains(string(got), "gpgcheck=0") {
		t.Errorf("expected disabled/no-gpgcheck flags, got %q", got)
	}
}

func TestYumRepository_CustomFileName(t *testing.T) {
	dir := t.TempDir()
	y := &YumRepository{ReposDir: dir}
	_, err := y.Run(context.Background(), map[string]any{
		"name": "myrepo", "baseurl": "https://example.com/repo", "file": "custom",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "custom.repo")); err != nil {
		t.Errorf("expected file at custom.repo: %v", err)
	}
}

func TestYumRepository_IdempotentWhenAlreadyMatching(t *testing.T) {
	dir := t.TempDir()
	y := &YumRepository{ReposDir: dir}
	args := map[string]any{"name": "myrepo", "baseurl": "https://example.com/repo"}
	if _, err := y.Run(context.Background(), args, false); err != nil {
		t.Fatal(err)
	}
	res, err := y.Run(context.Background(), args, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when stanza already matches")
	}
}

func TestYumRepository_AbsentRemovesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "myrepo.repo")
	if err := os.WriteFile(path, []byte("[myrepo]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	y := &YumRepository{ReposDir: dir}
	res, err := y.Run(context.Background(), map[string]any{"name": "myrepo", "state": "absent"}, false)
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

func TestYumRepository_AbsentIdempotentWhenMissing(t *testing.T) {
	dir := t.TempDir()
	y := &YumRepository{ReposDir: dir}
	res, err := y.Run(context.Background(), map[string]any{"name": "ghost", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing a repo that doesn't exist")
	}
}

func TestYumRepository_MissingBaseurlErrors(t *testing.T) {
	y := &YumRepository{ReposDir: t.TempDir()}
	_, err := y.Run(context.Background(), map[string]any{"name": "myrepo"}, false)
	if err == nil {
		t.Fatal("expected error when baseurl is missing for state=present")
	}
}

func TestYumRepository_PathTraversalFileRejected(t *testing.T) {
	y := &YumRepository{ReposDir: t.TempDir()}
	_, err := y.Run(context.Background(), map[string]any{
		"name": "myrepo", "baseurl": "https://example.com/repo", "file": "../escape",
	}, false)
	if err == nil {
		t.Fatal("expected error for a path-traversal file name")
	}
}

func TestYumRepository_DryRunDoesNotWrite(t *testing.T) {
	dir := t.TempDir()
	y := &YumRepository{ReposDir: dir}
	res, err := y.Run(context.Background(), map[string]any{
		"name": "myrepo", "baseurl": "https://example.com/repo", "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(filepath.Join(dir, "myrepo.repo")); !os.IsNotExist(err) {
		t.Error("expected no file created under dry_run")
	}
}
