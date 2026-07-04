package modules

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestSubversion_ChecksOutWhenDestNotAWorkingCopy(t *testing.T) {
	var calls []string
	s := &Subversion{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, name+" "+joinArgs(args))
		if len(args) > 0 && args[0] == "info" {
			return []byte("Revision: 42\n"), nil
		}
		return nil, nil
	}}
	dest := filepath.Join(t.TempDir(), "app")
	res, err := s.Run(context.Background(), map[string]any{"repo": "https://example.com/repo", "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true checking out into a fresh directory")
	}
	found := false
	for _, c := range calls {
		if c == "svn checkout --revision HEAD https://example.com/repo "+dest {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a checkout call, got %v", calls)
	}
}

func TestSubversion_CheckoutFailurePropagatesError(t *testing.T) {
	s := &Subversion{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte("svn: E170013: Unable to connect"), exitStatus(1)
	}}
	_, err := s.Run(context.Background(), map[string]any{
		"repo": "https://example.com/missing", "dest": filepath.Join(t.TempDir(), "app"),
	}, false)
	if err == nil {
		t.Fatal("expected error when checkout fails")
	}
}

func TestSubversion_DryRunCheckoutDoesNotCallSvn(t *testing.T) {
	called := false
	s := &Subversion{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		called = true
		return nil, nil
	}}
	res, err := s.Run(context.Background(), map[string]any{
		"repo": "https://example.com/repo", "dest": filepath.Join(t.TempDir(), "app"), "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if called {
		t.Error("expected dry_run to never call svn")
	}
}

func realSvnAvailable(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("svn"); err != nil {
		t.Skip("svn not available")
	}
	if _, err := exec.LookPath("svnadmin"); err != nil {
		t.Skip("svnadmin not available")
	}
}

// TestSubversion_RealCheckoutAndUpdate exercises the module against a real
// svn binary and a real local file:// repository — checks it out, adds a
// second commit, and confirms a repeat call updates to the new revision.
func TestSubversion_RealCheckoutAndUpdate(t *testing.T) {
	realSvnAvailable(t)

	repoDir := filepath.Join(t.TempDir(), "repo")
	if out, err := exec.Command("svnadmin", "create", repoDir).CombinedOutput(); err != nil {
		t.Fatalf("svnadmin create: %v: %s", err, out)
	}
	repoURL := "file://" + repoDir

	work := t.TempDir()
	if out, err := exec.Command("svn", "checkout", repoURL, work).CombinedOutput(); err != nil {
		t.Fatalf("svn checkout (seed): %v: %s", err, out)
	}
	if err := os.WriteFile(filepath.Join(work, "file.txt"), []byte("v1"), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("svn", "add", filepath.Join(work, "file.txt")).CombinedOutput(); err != nil {
		t.Fatalf("svn add: %v: %s", err, out)
	}
	if out, err := exec.Command("svn", "commit", "-m", "initial", work).CombinedOutput(); err != nil {
		t.Fatalf("svn commit: %v: %s", err, out)
	}

	dest := filepath.Join(t.TempDir(), "clone")
	s := NewSubversion()
	res, err := s.Run(context.Background(), map[string]any{"repo": repoURL, "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run (checkout): %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true on initial checkout")
	}
	got, err := os.ReadFile(filepath.Join(dest, "file.txt"))
	if err != nil {
		t.Fatalf("reading checked-out file: %v", err)
	}
	if string(got) != "v1" {
		t.Errorf("content = %q, want v1", got)
	}

	res2, err := s.Run(context.Background(), map[string]any{"repo": repoURL, "dest": dest}, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res2.Changed {
		t.Error("expected changed=false when already at the current revision")
	}

	if err := os.WriteFile(filepath.Join(work, "file.txt"), []byte("v2"), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("svn", "commit", "-m", "second", work).CombinedOutput(); err != nil {
		t.Fatalf("svn commit (2nd): %v: %s", err, out)
	}

	res3, err := s.Run(context.Background(), map[string]any{"repo": repoURL, "dest": dest}, false)
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
