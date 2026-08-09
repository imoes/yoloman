package modules

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestGit_ClonesWhenDestNotARepo(t *testing.T) {
	var calls []string
	g := &Git{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, name+" "+joinArgs(args))
		return nil, nil
	}}
	dest := filepath.Join(t.TempDir(), "app")
	res, err := g.Run(context.Background(), map[string]any{"repo": "https://example.com/repo.git", "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true cloning into a fresh directory")
	}
	found := false
	for _, c := range calls {
		if c == "git clone https://example.com/repo.git "+dest {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a plain clone call, got %v", calls)
	}
}

func TestGit_CloneFailurePropagatesError(t *testing.T) {
	g := &Git{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte("fatal: repository not found"), exitStatus(128)
	}}
	_, err := g.Run(context.Background(), map[string]any{
		"repo": "https://example.com/missing.git", "dest": filepath.Join(t.TempDir(), "app"),
	}, false)
	if err == nil {
		t.Fatal("expected error when clone fails")
	}
}

func TestGit_DryRunCloneDoesNotCallGit(t *testing.T) {
	called := false
	g := &Git{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		called = true
		return nil, nil
	}}
	res, err := g.Run(context.Background(), map[string]any{
		"repo": "https://example.com/repo.git", "dest": filepath.Join(t.TempDir(), "app"), "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if called {
		t.Error("expected dry_run to never call git")
	}
}

// realGitAvailable skips a test if git isn't installed.
func realGitAvailable(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=Test", "GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=Test", "GIT_COMMITTER_EMAIL=test@example.com")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, out)
	}
}

// TestGit_RealCloneAndUpdate exercises the module against a real git
// binary and a real local repository (no network) — clones it, then adds
// a second commit to the source and confirms a repeat call fetches and
// checks out the new commit.
func TestGit_RealCloneAndUpdate(t *testing.T) {
	realGitAvailable(t)

	src := t.TempDir()
	runGit(t, src, "init", "-b", "main")
	if err := os.WriteFile(filepath.Join(src, "file.txt"), []byte("v1"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, src, "add", ".")
	runGit(t, src, "commit", "-m", "initial")

	dest := filepath.Join(t.TempDir(), "clone")
	g := NewGit()
	res, err := g.Run(context.Background(), map[string]any{"repo": src, "dest": dest, "version": "main"}, false)
	if err != nil {
		t.Fatalf("Run (clone): %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true on initial clone")
	}
	got, err := os.ReadFile(filepath.Join(dest, "file.txt"))
	if err != nil {
		t.Fatalf("reading cloned file: %v", err)
	}
	if string(got) != "v1" {
		t.Errorf("content = %q, want v1", got)
	}

	// Idempotent: re-running against the same version does nothing.
	res2, err := g.Run(context.Background(), map[string]any{"repo": src, "dest": dest, "version": "main"}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res2.Changed {
		t.Error("expected changed=false when already at the desired version")
	}

	// New commit upstream: a repeat call should fetch and check it out.
	if err := os.WriteFile(filepath.Join(src, "file.txt"), []byte("v2"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, src, "add", ".")
	runGit(t, src, "commit", "-m", "second")

	res3, err := g.Run(context.Background(), map[string]any{"repo": src, "dest": dest, "version": "main"}, false)
	if err != nil {
		t.Fatalf("Run (update): %v", err)
	}
	if !res3.Changed {
		t.Error("expected changed=true after a new upstream commit")
	}
	got2, err := os.ReadFile(filepath.Join(dest, "file.txt"))
	if err != nil {
		t.Fatalf("reading updated file: %v", err)
	}
	if string(got2) != "v2" {
		t.Errorf("content = %q, want v2", got2)
	}
}
