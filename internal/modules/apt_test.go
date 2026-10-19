package modules

import (
	"context"
	"os/exec"
	"strings"
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
			action := ""
			for i := 0; i < len(args); i++ {
				if args[i] == "-o" {
					i++ // skip the option's value (DPkg::Lock::Timeout=…)
					continue
				}
				if args[i] != "-y" {
					action = args[i]
					break
				}
			}
			switch action {
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

// A preview fails where the real install would: no repository offers the package (measured: Ubuntu 26.04 "scx").
func TestApt_DryRunRefusesAPackageNoRepositoryOffers(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{}, candidate: map[string]string{"curl": "8.5.0"}}
	a := &Apt{Runner: fake.runner()}
	_, err := a.Run(context.Background(), map[string]any{"name": []string{"curl", "scx"}, "dry_run": true}, false)
	if err == nil || !strings.Contains(err.Error(), "scx has no installation candidate") {
		t.Fatalf("err = %v", err)
	}
	res, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}, "dry_run": true}, false)
	if err != nil || res.Data.([]map[string]any)[0]["would_install_version"] != "8.5.0" {
		t.Errorf("err=%v data=%v", err, res.Data)
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
		if c == "apt-get -o DPkg::Lock::Timeout=60 update" {
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

// TestApt_InstallFailurePropagatesError guards the write-error-propagation
// contract: if the underlying apt-get invocation itself fails (e.g. a
// broken package, unmet dependencies, network failure fetching the repo),
// Run must return a non-nil error — never silently report success.
func TestApt_InstallFailurePropagatesError(t *testing.T) {
	a := &Apt{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		switch name {
		case "dpkg-query":
			return nil, &exec.ExitError{} // not installed
		case "apt-cache":
			return []byte("Candidate: 8.5.0\n"), nil
		case "apt-get":
			return []byte("E: Unable to locate package curl"), &exec.ExitError{}
		}
		return nil, nil
	}}
	_, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}}, false)
	if err == nil {
		t.Fatal("expected error when apt-get install fails")
	}
}

// TestApt_UpdateCacheFailurePropagatesError: a failing `apt-get update`
// (e.g. an unreachable repository) must also surface as an error, not be
// silently swallowed before the install step runs.
func TestApt_UpdateCacheFailurePropagatesError(t *testing.T) {
	a := &Apt{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name == "apt-get" && len(args) > 0 && args[len(args)-1] == "update" {
			return []byte("E: Failed to fetch"), &exec.ExitError{}
		}
		return nil, nil
	}}
	_, err := a.Run(context.Background(), map[string]any{"name": []string{"curl"}, "update_cache": true}, false)
	if err == nil {
		t.Fatal("expected error when apt-get update fails")
	}
}

func TestApt_WaitsForTheDpkgLockAndReportsTheInstalledVersion(t *testing.T) {
	// "Could not get lock /var/lib/dpkg/lock-frontend" failed a role while another apt ran (Playwright B2), and a
	// fresh install reported installed_version "" (the version queried before the install).
	fake := &fakeApt{installed: map[string]string{}, candidate: map[string]string{"earlyoom": "1.8"}}
	a := &Apt{Runner: fake.runner()}
	res, err := a.Run(context.Background(), map[string]any{"name": []string{"earlyoom"}}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	var install string
	for _, c := range fake.calls {
		if len(c) > 7 && c[:7] == "apt-get" {
			install = c
		}
	}
	if install != "apt-get -o DPkg::Lock::Timeout=60 install -y earlyoom" {
		t.Fatalf("install call = %q", install)
	}
	data := res.Data.([]map[string]any)
	if data[0]["installed_version"] != "1.8" {
		t.Fatalf("installed_version = %v", data[0]["installed_version"])
	}
}
