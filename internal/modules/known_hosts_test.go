package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestKnownHosts_AppendsWhenAbsent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "known_hosts")
	if err := os.WriteFile(path, []byte("existing.com ssh-ed25519 EXISTING\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	k := NewKnownHosts()
	res, err := k.Run(context.Background(), map[string]any{
		"name": "github.com", "key": "github.com ssh-ed25519 AAAA1234", "path": path,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true appending a new entry")
	}
	got, _ := os.ReadFile(path)
	if !strings.Contains(string(got), "github.com ssh-ed25519 AAAA1234") {
		t.Errorf("expected appended entry, got %q", got)
	}
	if !strings.Contains(string(got), "existing.com") {
		t.Errorf("expected existing entry preserved, got %q", got)
	}
}

func TestKnownHosts_IdempotentWhenAlreadyMatching(t *testing.T) {
	path := filepath.Join(t.TempDir(), "known_hosts")
	k := NewKnownHosts()
	args := map[string]any{"name": "github.com", "key": "github.com ssh-ed25519 AAAA1234", "path": path}
	if _, err := k.Run(context.Background(), args, false); err != nil {
		t.Fatal(err)
	}
	res, err := k.Run(context.Background(), args, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when entry already matches")
	}
}

func TestKnownHosts_ReplacesChangedKeyInPlace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "known_hosts")
	if err := os.WriteFile(path, []byte("github.com ssh-ed25519 OLDKEY\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	k := NewKnownHosts()
	res, err := k.Run(context.Background(), map[string]any{
		"name": "github.com", "key": "github.com ssh-ed25519 NEWKEY", "path": path,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when the key differs")
	}
	got, _ := os.ReadFile(path)
	if strings.Contains(string(got), "OLDKEY") || !strings.Contains(string(got), "NEWKEY") {
		t.Errorf("expected key replaced, got %q", got)
	}
	if strings.Count(string(got), "github.com") != 1 {
		t.Errorf("expected exactly one entry (replace in place, not duplicate), got %q", got)
	}
}

func TestKnownHosts_AbsentRemovesEntry(t *testing.T) {
	path := filepath.Join(t.TempDir(), "known_hosts")
	if err := os.WriteFile(path, []byte("keep.com ssh-ed25519 KEEP\ngithub.com ssh-ed25519 REMOVE\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	k := NewKnownHosts()
	res, err := k.Run(context.Background(), map[string]any{"name": "github.com", "state": "absent", "path": path}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing an existing entry")
	}
	got, _ := os.ReadFile(path)
	if strings.Contains(string(got), "github.com") {
		t.Errorf("expected entry removed, got %q", got)
	}
	if !strings.Contains(string(got), "keep.com") {
		t.Errorf("expected unrelated entry preserved, got %q", got)
	}
}

func TestKnownHosts_AbsentIdempotentWhenMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "known_hosts")
	k := NewKnownHosts()
	res, err := k.Run(context.Background(), map[string]any{"name": "ghost.com", "state": "absent", "path": path}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing an entry that doesn't exist")
	}
}

func TestKnownHosts_CreatesFileWhenMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "new_known_hosts")
	k := NewKnownHosts()
	_, err := k.Run(context.Background(), map[string]any{
		"name": "github.com", "key": "github.com ssh-ed25519 AAAA1234", "path": path,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("expected file to be created: %v", err)
	}
}

func TestKnownHosts_MissingKeyForPresentErrors(t *testing.T) {
	k := NewKnownHosts()
	_, err := k.Run(context.Background(), map[string]any{"name": "github.com", "path": filepath.Join(t.TempDir(), "kh")}, false)
	if err == nil {
		t.Fatal("expected error when key is missing for state=present")
	}
}

func TestKnownHosts_DryRunDoesNotWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "known_hosts")
	k := NewKnownHosts()
	res, err := k.Run(context.Background(), map[string]any{
		"name": "github.com", "key": "github.com ssh-ed25519 AAAA1234", "path": path, "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("expected no file created under dry_run")
	}
}
