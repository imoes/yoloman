package modules

import (
	"context"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestPip_InstallsWhenNotPresent(t *testing.T) {
	var calls []string
	p := &Pip{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, name+" "+joinArgs(args))
		if len(args) > 0 && args[0] == "show" {
			return nil, exitStatus(1)
		}
		return nil, nil
	}}
	res, err := p.Run(context.Background(), map[string]any{"name": "requests"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true installing an absent package")
	}
	found := false
	for _, c := range calls {
		if c == "pip3 install requests" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected an install call, got %v", calls)
	}
}

func TestPip_PresentIsIdempotentWhenAlreadyInstalled(t *testing.T) {
	p := &Pip{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if len(args) > 0 && args[0] == "show" {
			return []byte("Name: requests\nVersion: 2.31.0\n"), nil
		}
		t.Fatalf("unexpected mutating call: %s %v", name, args)
		return nil, nil
	}}
	res, err := p.Run(context.Background(), map[string]any{"name": "requests"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when already installed")
	}
}

func TestPip_PinnedVersionMismatchTriggersReinstall(t *testing.T) {
	var calls []string
	p := &Pip{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, name+" "+joinArgs(args))
		if len(args) > 0 && args[0] == "show" {
			return []byte("Name: requests\nVersion: 2.0.0\n"), nil
		}
		return nil, nil
	}}
	res, err := p.Run(context.Background(), map[string]any{"name": "requests==2.31.0"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when installed version differs from pinned version")
	}
	found := false
	for _, c := range calls {
		if c == "pip3 install requests==2.31.0" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected an install call with the pinned spec, got %v", calls)
	}
}

func TestPip_AbsentUninstallsWhenPresent(t *testing.T) {
	var calls []string
	p := &Pip{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, name+" "+joinArgs(args))
		if len(args) > 0 && args[0] == "show" {
			return []byte("Name: requests\nVersion: 2.31.0\n"), nil
		}
		return nil, nil
	}}
	res, err := p.Run(context.Background(), map[string]any{"name": "requests", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true uninstalling a present package")
	}
	found := false
	for _, c := range calls {
		if c == "pip3 uninstall -y requests" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected an uninstall call, got %v", calls)
	}
}

func TestPip_AbsentIsIdempotentWhenNotPresent(t *testing.T) {
	p := &Pip{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if len(args) > 0 && args[0] == "show" {
			return nil, exitStatus(1)
		}
		t.Fatalf("unexpected mutating call: %s %v", name, args)
		return nil, nil
	}}
	res, err := p.Run(context.Background(), map[string]any{"name": "requests", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when already absent")
	}
}

func TestPip_LatestDetectsVersionChangeAfterUpgrade(t *testing.T) {
	showCount := 0
	p := &Pip{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if len(args) > 0 && args[0] == "show" {
			showCount++
			if showCount == 1 {
				return []byte("Name: requests\nVersion: 2.0.0\n"), nil
			}
			return []byte("Name: requests\nVersion: 2.31.0\n"), nil
		}
		return nil, nil
	}}
	res, err := p.Run(context.Background(), map[string]any{"name": "requests", "state": "latest"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when version differs before/after upgrade")
	}
}

func TestPip_DryRunDoesNotCallPip(t *testing.T) {
	called := false
	p := &Pip{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if len(args) > 0 && args[0] == "show" {
			return nil, exitStatus(1)
		}
		called = true
		return nil, nil
	}}
	res, err := p.Run(context.Background(), map[string]any{"name": "requests", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if called {
		t.Error("expected dry_run to never call a mutating pip command")
	}
}

func TestPip_InvalidStateRejected(t *testing.T) {
	p := NewPip()
	_, err := p.Run(context.Background(), map[string]any{"name": "requests", "state": "bogus"}, false)
	if err == nil {
		t.Fatal("expected error for an invalid state")
	}
}

// TestPip_RealVirtualenvInstall exercises the module against a real
// python3/pip in a throwaway virtualenv (no network — installs nothing,
// just proves venv creation + real `pip show` querying works end to end).
// A freshly created venv already bundles pip itself, so state=present for
// "pip" is expected to report changed=false — the assertion that matters
// here is that querying it via the real binary succeeds and finds a version.
func TestPip_RealVirtualenvInstall(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not available")
	}
	probe := filepath.Join(t.TempDir(), "probe")
	if out, err := exec.Command("python3", "-m", "venv", probe).CombinedOutput(); err != nil {
		t.Skipf("python3 -m venv not functional here (e.g. python3-venv not installed): %s", out)
	}
	venv := filepath.Join(t.TempDir(), "venv")
	p := NewPip()
	res, err := p.Run(context.Background(), map[string]any{"name": "pip", "virtualenv": venv}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, err := exec.LookPath(filepath.Join(venv, "bin", "pip")); err != nil {
		t.Errorf("expected a pip binary inside the created virtualenv: %v", err)
	}
	results, ok := res.Data.([]map[string]any)
	if !ok || len(results) != 1 {
		t.Fatalf("unexpected result data: %#v", res.Data)
	}
	if results[0]["installed_version"] == "" {
		t.Error("expected a non-empty installed_version for pip inside its own venv")
	}
}
