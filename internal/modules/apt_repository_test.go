package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestAptRepository_CreatesFileWhenAbsent(t *testing.T) {
	dir := t.TempDir()
	a := &AptRepository{SourcesDir: dir}
	res, err := a.Run(context.Background(), map[string]any{
		"repo": "deb https://example.com/repo stable main", "filename": "myrepo",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true creating a new repo file")
	}
	got, err := os.ReadFile(filepath.Join(dir, "myrepo.list"))
	if err != nil {
		t.Fatalf("reading created file: %v", err)
	}
	if string(got) != "deb https://example.com/repo stable main\n" {
		t.Errorf("content = %q", got)
	}
}

func TestAptRepository_IdempotentWhenAlreadyPresent(t *testing.T) {
	dir := t.TempDir()
	a := &AptRepository{SourcesDir: dir}
	args := map[string]any{"repo": "deb https://example.com/repo stable main", "filename": "myrepo"}
	if _, err := a.Run(context.Background(), args, false); err != nil {
		t.Fatal(err)
	}
	res, err := a.Run(context.Background(), args, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when entry already present")
	}
}

func TestAptRepository_AppendsToExistingFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "myrepo.list"), []byte("deb https://a.example.com stable main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := &AptRepository{SourcesDir: dir}
	_, err := a.Run(context.Background(), map[string]any{
		"repo": "deb https://b.example.com stable main", "filename": "myrepo",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "myrepo.list"))
	if string(got) != "deb https://a.example.com stable main\ndeb https://b.example.com stable main\n" {
		t.Errorf("content = %q", got)
	}
}

func TestAptRepository_AbsentRemovesLine(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "myrepo.list"), []byte("deb https://a.example.com stable main\ndeb https://b.example.com stable main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := &AptRepository{SourcesDir: dir}
	res, err := a.Run(context.Background(), map[string]any{
		"repo": "deb https://a.example.com stable main", "filename": "myrepo", "state": "absent",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing an existing entry")
	}
	got, _ := os.ReadFile(filepath.Join(dir, "myrepo.list"))
	if string(got) != "deb https://b.example.com stable main\n" {
		t.Errorf("content = %q", got)
	}
}

func TestAptRepository_AbsentRemovesFileWhenLastLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "myrepo.list")
	if err := os.WriteFile(path, []byte("deb https://a.example.com stable main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := &AptRepository{SourcesDir: dir}
	_, err := a.Run(context.Background(), map[string]any{
		"repo": "deb https://a.example.com stable main", "filename": "myrepo", "state": "absent",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("expected the now-empty repo file to be removed entirely")
	}
}

func TestAptRepository_AbsentIdempotentWhenMissing(t *testing.T) {
	dir := t.TempDir()
	a := &AptRepository{SourcesDir: dir}
	res, err := a.Run(context.Background(), map[string]any{
		"repo": "deb https://a.example.com stable main", "filename": "ghost", "state": "absent",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing a repo entry that doesn't exist")
	}
}

func TestAptRepository_UpdateCacheRunsAptGetUpdate(t *testing.T) {
	dir := t.TempDir()
	var calls []string
	a := &AptRepository{SourcesDir: dir, Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, name+" "+joinArgs(args))
		return nil, nil
	}}
	_, err := a.Run(context.Background(), map[string]any{
		"repo": "deb https://a.example.com stable main", "filename": "myrepo", "update_cache": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	found := false
	for _, c := range calls {
		if c == "apt-get update" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected apt-get update call, got %v", calls)
	}
}

func TestAptRepository_UpdateCacheFailurePropagatesError(t *testing.T) {
	dir := t.TempDir()
	a := &AptRepository{SourcesDir: dir, Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte("E: Failed to fetch"), exitStatus(1)
	}}
	_, err := a.Run(context.Background(), map[string]any{
		"repo": "deb https://a.example.com stable main", "filename": "myrepo", "update_cache": true,
	}, false)
	if err == nil {
		t.Fatal("expected error when apt-get update fails")
	}
}

func TestAptRepository_MissingRepoForPresentErrors(t *testing.T) {
	a := &AptRepository{SourcesDir: t.TempDir()}
	_, err := a.Run(context.Background(), map[string]any{"filename": "myrepo"}, false)
	if err == nil {
		t.Fatal("expected error when repo is missing for state=present")
	}
}

func TestAptRepository_PathTraversalFilenameRejected(t *testing.T) {
	a := &AptRepository{SourcesDir: t.TempDir()}
	_, err := a.Run(context.Background(), map[string]any{
		"repo": "deb https://a.example.com stable main", "filename": "../escape",
	}, false)
	if err == nil {
		t.Fatal("expected error for a path-traversal filename")
	}
}

func TestAptRepository_DryRunDoesNotWrite(t *testing.T) {
	dir := t.TempDir()
	a := &AptRepository{SourcesDir: dir}
	res, err := a.Run(context.Background(), map[string]any{
		"repo": "deb https://a.example.com stable main", "filename": "myrepo", "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(filepath.Join(dir, "myrepo.list")); !os.IsNotExist(err) {
		t.Error("expected no file created under dry_run")
	}
}
