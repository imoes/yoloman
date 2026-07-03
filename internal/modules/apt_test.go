package modules

import (
	"context"
	"os/exec"
	"testing"
)

// fakeApt simulates dpkg-query/apt-cache/apt-get for a small fixed set of
// packages, recording mutating apt-get calls.
type fakeApt struct {
	installed map[string]string // pkg -> installed version
	candidate map[string]string // pkg -> apt-cache candidate version
	calls     []string
}

func (f *fakeApt) runner() CommandRunner {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		f.calls = append(f.calls, name+" "+joinArgs(args))
		switch name {
		case "dpkg-query":
			pkg := args[len(args)-1]
			v, ok := f.installed[pkg]
			if !ok {
				return nil, &exec.ExitError{}
			}
			return []byte("install ok installed\t" + v), nil
		case "apt-cache":
			pkg := args[len(args)-1]
			c, ok := f.candidate[pkg]
			if !ok {
				return []byte("N: Unable to locate package " + pkg), &exec.ExitError{}
			}
			return []byte("Installed: (none)\nCandidate: " + c + "\n"), nil
		case "apt-get":
			switch args[0] {
			case "install":
				pkg := args[len(args)-1]
				f.installed[pkg] = f.candidate[pkg]
			case "remove":
				pkg := args[len(args)-1]
				delete(f.installed, pkg)
			}
			return nil, nil
		}
		return nil, nil
	}
}

func TestApt_PresentInstallsWhenMissing(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{}, candidate: map[string]string{"curl": "8.5.0"}}
	a := &Apt{Runner: fake.runner()}

	res, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true installing a missing package")
	}
	if fake.installed["curl"] != "8.5.0" {
		t.Errorf("expected curl installed, got %v", fake.installed)
	}
}

func TestApt_PresentIdempotentWhenInstalled(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{"curl": "8.5.0"}, candidate: map[string]string{"curl": "8.5.0"}}
	a := &Apt{Runner: fake.runner()}

	res, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when package already present (state=present)")
	}
}

func TestApt_AbsentRemovesWhenInstalled(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{"curl": "8.5.0"}, candidate: map[string]string{}}
	a := &Apt{Runner: fake.runner()}

	res, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}, "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true removing an installed package")
	}
	if _, ok := fake.installed["curl"]; ok {
		t.Error("expected curl to be removed")
	}
}

func TestApt_AbsentIdempotentWhenNotInstalled(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{}, candidate: map[string]string{}}
	a := &Apt{Runner: fake.runner()}
	res, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}, "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false removing an already-absent package")
	}
}

func TestApt_LatestUpgradesWhenOutdated(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{"curl": "8.4.0"}, candidate: map[string]string{"curl": "8.5.0"}}
	a := &Apt{Runner: fake.runner()}

	res, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}, "state": "latest"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true when candidate version differs from installed")
	}
	if fake.installed["curl"] != "8.5.0" {
		t.Errorf("expected curl upgraded to 8.5.0, got %v", fake.installed)
	}
}

func TestApt_LatestIdempotentWhenCurrent(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{"curl": "8.5.0"}, candidate: map[string]string{"curl": "8.5.0"}}
	a := &Apt{Runner: fake.runner()}
	res, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}, "state": "latest"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when already at candidate version")
	}
}

func TestApt_DryRunDoesNotMutate(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{}, candidate: map[string]string{"curl": "8.5.0"}}
	a := &Apt{Runner: fake.runner()}
	res, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}, "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, ok := fake.installed["curl"]; ok {
		t.Error("expected dry_run to not actually install")
	}
}

func TestApt_UpdateCacheCallsAptGetUpdate(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{"curl": "8.5.0"}, candidate: map[string]string{"curl": "8.5.0"}}
	a := &Apt{Runner: fake.runner()}
	if _, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}, "update_cache": true}, false); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range fake.calls {
		if c == "apt-get update" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected apt-get update call, got %v", fake.calls)
	}
}

func TestApt_SingleStringName(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{}, candidate: map[string]string{"curl": "8.5.0"}}
	a := &Apt{Runner: fake.runner()}
	res, err := a.Run(context.Background(), map[string]any{"name": "curl"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true with a single string name")
	}
}

func TestApt_InvalidState(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{}, candidate: map[string]string{}}
	a := &Apt{Runner: fake.runner()}
	if _, err := a.Run(context.Background(), map[string]any{"name": "curl", "state": "bogus"}, false); err == nil {
		t.Fatal("expected error for invalid state")
	}
}
