package modules

import (
	"context"
	"testing"
)

func TestHostname_IdempotentWhenAlreadySet(t *testing.T) {
	var calls []string
	h := &Hostname{
		CurrentHost: func() (string, error) { return "web01", nil },
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			calls = append(calls, name)
			return nil, nil
		},
	}
	res, err := h.Run(context.Background(), map[string]any{"name": "web01"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when hostname already matches")
	}
	if len(calls) != 0 {
		t.Errorf("expected no hostnamectl call, got %v", calls)
	}
}

func TestHostname_UpdatesWhenDifferent(t *testing.T) {
	var gotArgs []string
	h := &Hostname{
		CurrentHost: func() (string, error) { return "old-name", nil },
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			gotArgs = args
			return nil, nil
		},
	}
	res, err := h.Run(context.Background(), map[string]any{"name": "new-name"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when hostname differs")
	}
	if len(gotArgs) != 2 || gotArgs[0] != "set-hostname" || gotArgs[1] != "new-name" {
		t.Errorf("unexpected hostnamectl args: %v", gotArgs)
	}
}

func TestHostname_FailurePropagatesError(t *testing.T) {
	h := &Hostname{
		CurrentHost: func() (string, error) { return "old-name", nil },
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return []byte("Could not set hostname: Access denied"), exitStatus(1)
		},
	}
	_, err := h.Run(context.Background(), map[string]any{"name": "new-name"}, false)
	if err == nil {
		t.Fatal("expected error when hostnamectl fails")
	}
}

func TestHostname_DryRunDoesNotApply(t *testing.T) {
	called := false
	h := &Hostname{
		CurrentHost: func() (string, error) { return "old-name", nil },
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			called = true
			return nil, nil
		},
	}
	res, err := h.Run(context.Background(), map[string]any{"name": "new-name", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if called {
		t.Error("expected dry_run to not call hostnamectl")
	}
}
