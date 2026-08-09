package modules

import (
	"context"
	"testing"
)

// fakeRPM simulates rpm -q / <binary> install|remove|update for a small
// fixed set of packages, recording mutating calls. installed maps package
// name -> installed version.
type fakeRPM struct {
	installed map[string]string
	// updateResult, if set, is applied to installed[pkg] the next time
	// <binary> update -y <pkg> runs — simulating a real repo having a
	// newer version available.
	updateResult map[string]string
	calls        []string
}

func (f *fakeRPM) runner(binary string) CommandRunner {
	return func(ctx context.Context, name string, args ...string) ([]byte, error) {
		f.calls = append(f.calls, name+" "+joinArgs(args))
		switch name {
		case "rpm":
			// rpm -q --queryformat ... <pkg>
			pkg := args[len(args)-1]
			v, ok := f.installed[pkg]
			if !ok {
				return nil, exitStatus(1)
			}
			return []byte(v), nil
		case binary:
			pkg := args[len(args)-1]
			switch args[0] {
			case "install":
				if v, ok := f.updateResult[pkg]; ok {
					f.installed[pkg] = v
				} else {
					f.installed[pkg] = "1.0-1"
				}
			case "remove":
				delete(f.installed, pkg)
			case "update":
				if v, ok := f.updateResult[pkg]; ok {
					f.installed[pkg] = v
				}
			}
		}
		return nil, nil
	}
}

// rpmModule abstracts over Yum/Dnf/Dnf5 so the same test bodies exercise
// all three real Module implementations, not just the shared core.
type rpmModule interface {
	Module
	setRunner(CommandRunner)
}

func (y *Yum) setRunner(r CommandRunner)  { y.Runner = r }
func (d *Dnf) setRunner(r CommandRunner)  { d.Runner = r }
func (d *Dnf5) setRunner(r CommandRunner) { d.Runner = r }

func rpmModuleImpls() []struct {
	binary string
	module rpmModule
} {
	return []struct {
		binary string
		module rpmModule
	}{
		{"yum", &Yum{}},
		{"dnf", &Dnf{}},
		{"dnf5", &Dnf5{}},
	}
}

func TestRPMPackageManagers_PresentInstallsWhenMissing(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{}}
			impl.module.setRunner(fake.runner(impl.binary))
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}}, false)
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if !res.Changed {
				t.Error("expected changed=true installing a missing package")
			}
			if _, ok := fake.installed["httpd"]; !ok {
				t.Error("expected package to be installed")
			}
		})
	}
}

func TestRPMPackageManagers_PresentIdempotentWhenInstalled(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{"httpd": "1.0-1"}}
			impl.module.setRunner(fake.runner(impl.binary))
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}}, false)
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if res.Changed {
				t.Error("expected changed=false when already installed")
			}
		})
	}
}

func TestRPMPackageManagers_AbsentRemovesWhenInstalled(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{"httpd": "1.0-1"}}
			impl.module.setRunner(fake.runner(impl.binary))
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}, "state": "absent"}, false)
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if !res.Changed {
				t.Error("expected changed=true removing an installed package")
			}
			if _, ok := fake.installed["httpd"]; ok {
				t.Error("expected package to be removed")
			}
		})
	}
}

func TestRPMPackageManagers_AbsentIdempotentWhenMissing(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{}}
			impl.module.setRunner(fake.runner(impl.binary))
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}, "state": "absent"}, false)
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if res.Changed {
				t.Error("expected changed=false when already absent")
			}
		})
	}
}

func TestRPMPackageManagers_LatestInstallsWhenMissing(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{}}
			impl.module.setRunner(fake.runner(impl.binary))
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}, "state": "latest"}, false)
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if !res.Changed {
				t.Error("expected changed=true installing a missing package for state=latest")
			}
		})
	}
}

func TestRPMPackageManagers_LatestUpgradesWhenNewerAvailable(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{
				installed:    map[string]string{"httpd": "1.0-1"},
				updateResult: map[string]string{"httpd": "2.0-1"},
			}
			impl.module.setRunner(fake.runner(impl.binary))
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}, "state": "latest"}, false)
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if !res.Changed {
				t.Error("expected changed=true when a newer version is available")
			}
			if fake.installed["httpd"] != "2.0-1" {
				t.Errorf("installed version = %q, want 2.0-1", fake.installed["httpd"])
			}
		})
	}
}

func TestRPMPackageManagers_LatestNoOpWhenAlreadyCurrent(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{"httpd": "1.0-1"}}
			impl.module.setRunner(fake.runner(impl.binary))
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}, "state": "latest"}, false)
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if res.Changed {
				t.Error("expected changed=false when update leaves the version unchanged")
			}
		})
	}
}

func TestRPMPackageManagers_InvalidState(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{}}
			impl.module.setRunner(fake.runner(impl.binary))
			_, err := impl.module.Run(context.Background(), map[string]any{"name": "httpd", "state": "bogus"}, false)
			if err == nil {
				t.Fatal("expected error for invalid state")
			}
		})
	}
}

func TestRPMPackageManagers_DryRunDoesNotMutate(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{}}
			impl.module.setRunner(fake.runner(impl.binary))
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}, "dry_run": true}, false)
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if !res.Changed {
				t.Error("expected changed=true (predicted) under dry_run")
			}
			if _, ok := fake.installed["httpd"]; ok {
				t.Error("expected dry_run to not actually install")
			}
		})
	}
}

func TestRPMPackageManagers_InstallFailurePropagatesError(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			impl.module.setRunner(func(ctx context.Context, name string, args ...string) ([]byte, error) {
				if name == "rpm" {
					return nil, exitStatus(1)
				}
				return []byte("Error: Unable to find a match: httpd"), exitStatus(1)
			})
			_, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}}, false)
			if err == nil {
				t.Fatal("expected error when install fails")
			}
		})
	}
}

func TestRPMPackageManagers_SingleStringName(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{}}
			impl.module.setRunner(fake.runner(impl.binary))
			res, err := impl.module.Run(context.Background(), map[string]any{"name": "httpd"}, false)
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if !res.Changed {
				t.Error("expected changed=true with a single string name")
			}
		})
	}
}
