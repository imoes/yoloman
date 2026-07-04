package modules

import (
	"context"
	"testing"
)

// Note: unlike most other modules in this package, Reboot has no real-host
// integration test — deliberately. Actually rebooting the shared test host
// (host1.example.internal) mid test-run would be destructive to
// whatever else is running there, and the module has no way to observe its
// own success anyway (see the architectural limitation documented in
// reboot.go: the process runs on the host being rebooted). Coverage here is
// therefore fake-Runner-only, verifying the exact command issued and that
// dry_run never issues anything — matching the precedent already set for
// this project's other high-blast-radius commands (rpm_key's real gpg-key
// verification stopped short of touching production repos; iptables' real
// test used an isolated, unreferenced custom chain rather than the live
// INPUT/OUTPUT/FORWARD chains).
func TestReboot_IssuesShutdownWithDefaultMessage(t *testing.T) {
	var calls []string
	r := &Reboot{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, name+" "+joinArgs(args))
		return nil, nil
	}}
	res, err := r.Run(context.Background(), map[string]any{}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true issuing a reboot")
	}
	found := false
	for _, c := range calls {
		if c == "shutdown -r now Reboot initiated by agentic-mcp" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a shutdown call with the default message, got %v", calls)
	}
}

func TestReboot_CustomMessagePassedThrough(t *testing.T) {
	var calls []string
	r := &Reboot{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, name+" "+joinArgs(args))
		return nil, nil
	}}
	_, err := r.Run(context.Background(), map[string]any{"msg": "kernel update"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	found := false
	for _, c := range calls {
		if c == "shutdown -r now kernel update" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a shutdown call with the custom message, got %v", calls)
	}
}

func TestReboot_FailurePropagatesError(t *testing.T) {
	r := &Reboot{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte("shutdown: not found"), exitStatus(127)
	}}
	_, err := r.Run(context.Background(), map[string]any{}, false)
	if err == nil {
		t.Fatal("expected error when shutdown fails to run")
	}
}

func TestReboot_DryRunDoesNotCallShutdown(t *testing.T) {
	called := false
	r := &Reboot{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		called = true
		return nil, nil
	}}
	res, err := r.Run(context.Background(), map[string]any{"dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if called {
		t.Error("expected dry_run to never call shutdown")
	}
}
