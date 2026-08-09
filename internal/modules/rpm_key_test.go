package modules

import (
	"context"
	"testing"
)

// fakeRpmKeys simulates `rpm -qa gpg-pubkey-<id>-*` / `rpm --import` /
// `rpm -e` for a small fixed set of imported keys, recording mutating
// calls. imported maps key ID (lowercase, last 8 hex chars) -> full
// pseudo-package name.
type fakeRpmKeys struct {
	imported map[string]string
	calls    []string
}

func (f *fakeRpmKeys) runner() CommandRunner {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		f.calls = append(f.calls, name+" "+joinArgs(args))
		switch {
		case name == "rpm" && len(args) >= 2 && args[0] == "-qa":
			pattern := args[1] // "gpg-pubkey-<id>-*"
			id := pattern[len("gpg-pubkey-") : len(pattern)-len("-*")]
			pkgName, ok := f.imported[id]
			if !ok {
				return nil, exitStatus(1)
			}
			return []byte(pkgName + "\n"), nil
		case name == "rpm" && len(args) >= 2 && args[0] == "--import":
			f.imported["deadbeef"] = "gpg-pubkey-deadbeef-12345678"
		case name == "rpm" && len(args) >= 2 && args[0] == "-e":
			for id, pkg := range f.imported {
				if pkg == args[1] {
					delete(f.imported, id)
				}
			}
		}
		return nil, nil
	}
}

func TestRpmKey_ImportsWhenMissing(t *testing.T) {
	fake := &fakeRpmKeys{imported: map[string]string{}}
	r := &RpmKey{Runner: fake.runner()}
	res, err := r.Run(context.Background(), map[string]any{
		"key": "https://example.com/RPM-GPG-KEY", "fingerprint": "ABCD1234DEADBEEF",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true importing a new key")
	}
	if _, ok := fake.imported["deadbeef"]; !ok {
		t.Error("expected key to be imported")
	}
}

func TestRpmKey_IdempotentWhenAlreadyImported(t *testing.T) {
	fake := &fakeRpmKeys{imported: map[string]string{"deadbeef": "gpg-pubkey-deadbeef-12345678"}}
	r := &RpmKey{Runner: fake.runner()}
	res, err := r.Run(context.Background(), map[string]any{
		"key": "https://example.com/RPM-GPG-KEY", "fingerprint": "ABCD1234DEADBEEF",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when key already imported")
	}
}

func TestRpmKey_AbsentRemovesExisting(t *testing.T) {
	fake := &fakeRpmKeys{imported: map[string]string{"deadbeef": "gpg-pubkey-deadbeef-12345678"}}
	r := &RpmKey{Runner: fake.runner()}
	res, err := r.Run(context.Background(), map[string]any{"fingerprint": "ABCD1234DEADBEEF", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing an existing key")
	}
	if _, ok := fake.imported["deadbeef"]; ok {
		t.Error("expected key to be removed")
	}
}

func TestRpmKey_AbsentIdempotentWhenMissing(t *testing.T) {
	fake := &fakeRpmKeys{imported: map[string]string{}}
	r := &RpmKey{Runner: fake.runner()}
	res, err := r.Run(context.Background(), map[string]any{"fingerprint": "ABCD1234DEADBEEF", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing a key that doesn't exist")
	}
}

func TestRpmKey_MissingKeyForNewImportErrors(t *testing.T) {
	fake := &fakeRpmKeys{imported: map[string]string{}}
	r := &RpmKey{Runner: fake.runner()}
	_, err := r.Run(context.Background(), map[string]any{"fingerprint": "ABCD1234DEADBEEF"}, false)
	if err == nil {
		t.Fatal("expected error when key is missing and the key isn't already imported")
	}
}

func TestRpmKey_ShortFingerprintRejected(t *testing.T) {
	fake := &fakeRpmKeys{imported: map[string]string{}}
	r := &RpmKey{Runner: fake.runner()}
	_, err := r.Run(context.Background(), map[string]any{"key": "x", "fingerprint": "ABCD"}, false)
	if err == nil {
		t.Fatal("expected error for a too-short fingerprint")
	}
}

func TestRpmKey_ImportFailurePropagatesError(t *testing.T) {
	r := &RpmKey{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if args[0] == "-qa" {
			return nil, exitStatus(1)
		}
		return []byte("error: not an rpm package"), exitStatus(1)
	}}
	_, err := r.Run(context.Background(), map[string]any{"key": "bad-key", "fingerprint": "ABCD1234DEADBEEF"}, false)
	if err == nil {
		t.Fatal("expected error when rpm --import fails")
	}
}

func TestRpmKey_DryRunDoesNotMutate(t *testing.T) {
	fake := &fakeRpmKeys{imported: map[string]string{}}
	r := &RpmKey{Runner: fake.runner()}
	res, err := r.Run(context.Background(), map[string]any{
		"key": "https://example.com/RPM-GPG-KEY", "fingerprint": "ABCD1234DEADBEEF", "dry_run": true,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, ok := fake.imported["deadbeef"]; ok {
		t.Error("expected dry_run to not actually import the key")
	}
}
