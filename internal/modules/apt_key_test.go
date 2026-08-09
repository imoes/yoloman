package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeGPG simulates `gpg --dearmor` by deterministically transforming the
// input text, so idempotency/content-comparison logic can be tested without
// needing a real gpg binary or a real key.
func fakeGPGDearmor() CommandRunnerWithStdin {
	return func(ctx context.Context, stdin string, name string, args ...string) ([]byte, error) {
		return []byte("DEARMORED:" + stdin), nil
	}
}

func TestAptKey_CreatesFromData(t *testing.T) {
	dir := t.TempDir()
	a := &AptKey{RunnerStdin: fakeGPGDearmor(), KeyringDir: dir}
	res, err := a.Run(context.Background(), map[string]any{"id": "docker", "data": "FAKE-ARMORED-KEY"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true creating a new key")
	}
	got, err := os.ReadFile(filepath.Join(dir, "docker.gpg"))
	if err != nil {
		t.Fatalf("reading created keyring: %v", err)
	}
	if string(got) != "DEARMORED:FAKE-ARMORED-KEY" {
		t.Errorf("content = %q", got)
	}
}

func TestAptKey_CreatesFromURL(t *testing.T) {
	dir := t.TempDir()
	a := &AptKey{
		RunnerStdin: fakeGPGDearmor(),
		KeyringDir:  dir,
		HTTPGet:     func(url string) ([]byte, error) { return []byte("KEY-FROM-" + url), nil },
	}
	_, err := a.Run(context.Background(), map[string]any{"id": "docker", "url": "https://example.com/key.asc"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "docker.gpg"))
	if string(got) != "DEARMORED:KEY-FROM-https://example.com/key.asc" {
		t.Errorf("content = %q", got)
	}
}

func TestAptKey_IdempotentWhenAlreadyMatching(t *testing.T) {
	dir := t.TempDir()
	a := &AptKey{RunnerStdin: fakeGPGDearmor(), KeyringDir: dir}
	args := map[string]any{"id": "docker", "data": "FAKE-ARMORED-KEY"}
	if _, err := a.Run(context.Background(), args, false); err != nil {
		t.Fatal(err)
	}
	res, err := a.Run(context.Background(), args, false)
	if err != nil {
		t.Fatalf("Run (2nd): %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when key content already matches")
	}
}

func TestAptKey_UpdatesWhenDifferent(t *testing.T) {
	dir := t.TempDir()
	a := &AptKey{RunnerStdin: fakeGPGDearmor(), KeyringDir: dir}
	if _, err := a.Run(context.Background(), map[string]any{"id": "docker", "data": "KEY-V1"}, false); err != nil {
		t.Fatal(err)
	}
	res, err := a.Run(context.Background(), map[string]any{"id": "docker", "data": "KEY-V2"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when key content differs")
	}
}

func TestAptKey_AbsentRemovesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "docker.gpg")
	if err := os.WriteFile(path, []byte("somekey"), 0o644); err != nil {
		t.Fatal(err)
	}
	a := &AptKey{RunnerStdin: fakeGPGDearmor(), KeyringDir: dir}
	res, err := a.Run(context.Background(), map[string]any{"id": "docker", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing an existing key")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("expected keyring file to be removed")
	}
}

func TestAptKey_AbsentIdempotentWhenMissing(t *testing.T) {
	dir := t.TempDir()
	a := &AptKey{RunnerStdin: fakeGPGDearmor(), KeyringDir: dir}
	res, err := a.Run(context.Background(), map[string]any{"id": "ghost", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing a key that doesn't exist")
	}
}

func TestAptKey_BothDataAndURLRejected(t *testing.T) {
	a := &AptKey{RunnerStdin: fakeGPGDearmor(), KeyringDir: t.TempDir()}
	_, err := a.Run(context.Background(), map[string]any{"id": "docker", "data": "x", "url": "https://example.com"}, false)
	if err == nil {
		t.Fatal("expected error when both data and url are given")
	}
}

func TestAptKey_NeitherDataNorURLRejected(t *testing.T) {
	a := &AptKey{RunnerStdin: fakeGPGDearmor(), KeyringDir: t.TempDir()}
	_, err := a.Run(context.Background(), map[string]any{"id": "docker"}, false)
	if err == nil {
		t.Fatal("expected error when neither data nor url is given")
	}
}

func TestAptKey_PathTraversalIDRejected(t *testing.T) {
	a := &AptKey{RunnerStdin: fakeGPGDearmor(), KeyringDir: t.TempDir()}
	_, err := a.Run(context.Background(), map[string]any{"id": "../escape", "data": "x"}, false)
	if err == nil {
		t.Fatal("expected error for a path-traversal id")
	}
}

func TestAptKey_DearmorFailurePropagatesError(t *testing.T) {
	a := &AptKey{
		RunnerStdin: func(ctx context.Context, stdin string, name string, args ...string) ([]byte, error) {
			return []byte("gpg: no valid OpenPGP data found"), exitStatus(2)
		},
		KeyringDir: t.TempDir(),
	}
	_, err := a.Run(context.Background(), map[string]any{"id": "docker", "data": "not a real key"}, false)
	if err == nil {
		t.Fatal("expected error when gpg --dearmor fails")
	}
}

func TestAptKey_HTTPFetchFailurePropagatesError(t *testing.T) {
	a := &AptKey{
		RunnerStdin: fakeGPGDearmor(),
		KeyringDir:  t.TempDir(),
		HTTPGet:     func(url string) ([]byte, error) { return nil, os.ErrDeadlineExceeded },
	}
	_, err := a.Run(context.Background(), map[string]any{"id": "docker", "url": "https://example.com/key.asc"}, false)
	if err == nil {
		t.Fatal("expected error when fetching the key URL fails")
	}
}

func TestAptKey_DryRunDoesNotWrite(t *testing.T) {
	dir := t.TempDir()
	a := &AptKey{RunnerStdin: fakeGPGDearmor(), KeyringDir: dir}
	res, err := a.Run(context.Background(), map[string]any{"id": "docker", "data": "x", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(filepath.Join(dir, "docker.gpg")); !os.IsNotExist(err) {
		t.Error("expected no file created under dry_run")
	}
}

// TestAptKey_RealGPGDearmor exercises the module against the real gpg
// binary (not a fake), using a freshly generated real OpenPGP key exported
// in armored form — proving the actual `gpg --dearmor` invocation and
// stdin-piping path work end to end, not just the surrounding logic.
// GNUPGHOME is isolated via t.Setenv, which defaultCommandRunnerWithStdin's
// child processes inherit automatically (no special env plumbing needed).
func TestAptKey_RealGPGDearmor(t *testing.T) {
	if _, err := os.Stat("/usr/bin/gpg"); err != nil {
		t.Skip("gpg not available")
	}
	t.Setenv("GNUPGHOME", t.TempDir())

	ctx := context.Background()
	if _, err := defaultCommandRunner(ctx, "gpg", "--batch", "--passphrase", "", "--quick-generate-key", "apt-key-test@example.com", "default", "default", "never"); err != nil {
		t.Skipf("gpg key generation unavailable in this environment: %v", err)
	}
	armored, err := defaultCommandRunner(ctx, "gpg", "--armor", "--export", "apt-key-test@example.com")
	if err != nil {
		t.Fatalf("exporting armored key: %v", err)
	}
	if !strings.Contains(string(armored), "BEGIN PGP PUBLIC KEY BLOCK") {
		t.Fatalf("expected armored key export, got %q", armored)
	}

	dir := t.TempDir()
	a := &AptKey{RunnerStdin: defaultCommandRunnerWithStdin, KeyringDir: dir}
	res, err := a.Run(ctx, map[string]any{"id": "realtest", "data": string(armored)}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true")
	}
	got, err := os.ReadFile(filepath.Join(dir, "realtest.gpg"))
	if err != nil {
		t.Fatalf("reading dearmored keyring: %v", err)
	}
	// A real dearmored OpenPGP key is binary, not ASCII-armored text — it
	// must not start with the armor header's "-----BEGIN" dash.
	if len(got) == 0 || got[0] == '-' {
		t.Errorf("expected real binary OpenPGP data, got %q", got)
	}
}
