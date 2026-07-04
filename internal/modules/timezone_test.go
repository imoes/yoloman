package modules

import (
	"context"
	"fmt"
	"testing"
)

func TestTimezone_IdempotentWhenAlreadySet(t *testing.T) {
	var calls []string
	tz := &Timezone{
		Readlink: func(path string) (string, error) { return "/usr/share/zoneinfo/Europe/Berlin", nil },
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			calls = append(calls, name)
			return nil, nil
		},
	}
	res, err := tz.Run(context.Background(), map[string]any{"name": "Europe/Berlin"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when timezone already matches")
	}
	if len(calls) != 0 {
		t.Errorf("expected no timedatectl call, got %v", calls)
	}
}

func TestTimezone_UpdatesWhenDifferent(t *testing.T) {
	var gotArgs []string
	tz := &Timezone{
		Readlink: func(path string) (string, error) { return "/usr/share/zoneinfo/UTC", nil },
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			gotArgs = args
			return nil, nil
		},
	}
	res, err := tz.Run(context.Background(), map[string]any{"name": "Europe/Berlin"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when timezone differs")
	}
	if len(gotArgs) != 2 || gotArgs[0] != "set-timezone" || gotArgs[1] != "Europe/Berlin" {
		t.Errorf("unexpected timedatectl args: %v", gotArgs)
	}
}

func TestTimezone_UnrecognizedLocaltimeTargetErrors(t *testing.T) {
	tz := &Timezone{
		Readlink: func(path string) (string, error) { return "/some/weird/path", nil },
	}
	_, err := tz.Run(context.Background(), map[string]any{"name": "UTC"}, false)
	if err == nil {
		t.Fatal("expected error for an unrecognized /etc/localtime target")
	}
}

func TestTimezone_ReadlinkFailurePropagatesError(t *testing.T) {
	tz := &Timezone{
		Readlink: func(path string) (string, error) { return "", fmt.Errorf("no such file") },
	}
	_, err := tz.Run(context.Background(), map[string]any{"name": "UTC"}, false)
	if err == nil {
		t.Fatal("expected error when reading /etc/localtime fails")
	}
}

func TestTimezone_FailurePropagatesError(t *testing.T) {
	tz := &Timezone{
		Readlink: func(path string) (string, error) { return "/usr/share/zoneinfo/UTC", nil },
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return []byte("Invalid timezone 'Bogus/Zone'"), exitStatus(1)
		},
	}
	_, err := tz.Run(context.Background(), map[string]any{"name": "Bogus/Zone"}, false)
	if err == nil {
		t.Fatal("expected error when timedatectl fails")
	}
}

func TestTimezone_DryRunDoesNotApply(t *testing.T) {
	called := false
	tz := &Timezone{
		Readlink: func(path string) (string, error) { return "/usr/share/zoneinfo/UTC", nil },
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			called = true
			return nil, nil
		},
	}
	res, err := tz.Run(context.Background(), map[string]any{"name": "Europe/Berlin", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if called {
		t.Error("expected dry_run to not call timedatectl")
	}
}
