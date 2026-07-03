package modules

import (
	"context"
	"os/exec"
	"testing"
)

// fakeSystemctl simulates systemctl's is-active/is-enabled query behavior
// (non-zero exit for a normal "not active"/"not enabled" answer) and records
// mutating calls.
type fakeSystemctl struct {
	active  bool
	enabled bool
	calls   []string
}

func (f *fakeSystemctl) runner() CommandRunner {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		f.calls = append(f.calls, name+" "+joinArgs(args))
		switch args[0] {
		case "is-active":
			if f.active {
				return []byte("active\n"), nil
			}
			return []byte("inactive\n"), &exec.ExitError{}
		case "is-enabled":
			if f.enabled {
				return []byte("enabled\n"), nil
			}
			return []byte("disabled\n"), &exec.ExitError{}
		case "start":
			f.active = true
		case "stop":
			f.active = false
		case "restart", "reload":
			f.active = true
		case "enable":
			f.enabled = true
		case "disable":
			f.enabled = false
		}
		return nil, nil
	}
}

func joinArgs(args []string) string {
	out := ""
	for i, a := range args {
		if i > 0 {
			out += " "
		}
		out += a
	}
	return out
}

func TestSystemd_StartsWhenInactive(t *testing.T) {
	fake := &fakeSystemctl{active: false}
	s := &Systemd{Runner: fake.runner()}

	res, err := s.Run(context.Background(), map[string]any{"name": "nginx", "state": "started"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true starting an inactive unit")
	}
	if !fake.active {
		t.Error("expected unit to be active after Run")
	}
}

func TestSystemd_IdempotentWhenAlreadyActive(t *testing.T) {
	fake := &fakeSystemctl{active: true}
	s := &Systemd{Runner: fake.runner()}

	res, err := s.Run(context.Background(), map[string]any{"name": "nginx", "state": "started"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when already active")
	}
}

func TestSystemd_StopsWhenActive(t *testing.T) {
	fake := &fakeSystemctl{active: true}
	s := &Systemd{Runner: fake.runner()}

	res, err := s.Run(context.Background(), map[string]any{"name": "nginx", "state": "stopped"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true stopping an active unit")
	}
	if fake.active {
		t.Error("expected unit to be inactive after Run")
	}
}

func TestSystemd_RestartedAlwaysChanged(t *testing.T) {
	fake := &fakeSystemctl{active: true}
	s := &Systemd{Runner: fake.runner()}

	res, err := s.Run(context.Background(), map[string]any{"name": "nginx", "state": "restarted"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true for restarted (always an action)")
	}
}

func TestSystemd_DryRunDoesNotMutate(t *testing.T) {
	fake := &fakeSystemctl{active: false}
	s := &Systemd{Runner: fake.runner()}

	res, err := s.Run(context.Background(), map[string]any{"name": "nginx", "state": "started", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if fake.active {
		t.Error("expected dry_run to not actually start the unit")
	}
	for _, c := range fake.calls {
		if c == "systemctl start nginx.service" {
			t.Errorf("expected no mutating call under dry_run, got %v", fake.calls)
		}
	}
}

func TestSystemd_EnabledManagement(t *testing.T) {
	fake := &fakeSystemctl{enabled: false}
	s := &Systemd{Runner: fake.runner()}

	res, err := s.Run(context.Background(), map[string]any{"name": "nginx", "enabled": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true enabling a disabled unit")
	}
	if !fake.enabled {
		t.Error("expected unit to be enabled after Run")
	}
}

func TestSystemd_UnitNameGetsServiceSuffix(t *testing.T) {
	fake := &fakeSystemctl{active: false}
	s := &Systemd{Runner: fake.runner()}
	if _, err := s.Run(context.Background(), map[string]any{"name": "nginx", "state": "started"}, false); err != nil {
		t.Fatal(err)
	}
	for _, c := range fake.calls {
		if c == "systemctl is-active nginx.service" {
			return
		}
	}
	t.Errorf("expected a call querying nginx.service, got %v", fake.calls)
}

func TestSystemd_InvalidState(t *testing.T) {
	fake := &fakeSystemctl{}
	s := &Systemd{Runner: fake.runner()}
	if _, err := s.Run(context.Background(), map[string]any{"name": "nginx", "state": "bogus"}, false); err == nil {
		t.Fatal("expected error for invalid state")
	}
}

func TestService_IsAliasOfSystemd(t *testing.T) {
	fake := &fakeSystemctl{active: false}
	svc := &Service{Systemd: &Systemd{Runner: fake.runner()}}
	if svc.Name() != "service" {
		t.Errorf("Name() = %q, want service", svc.Name())
	}
	res, err := svc.Run(context.Background(), map[string]any{"name": "nginx", "state": "started"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed || !fake.active {
		t.Error("expected service alias to behave like systemd module")
	}
}
