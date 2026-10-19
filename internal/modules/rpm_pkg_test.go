package modules

import (
	"context"
	"fmt"
	"strings"
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
	// unavailable lists packages no repository offers (`<binary> -q list --available` finds nothing).
	unavailable map[string]bool
	calls       []string
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
			if args[0] == "-q" && len(args) > 2 && args[1] == "list" {
				if f.unavailable[pkg] {
					return []byte("Error: No matching Packages to list\n"), exitStatus(1)
				}
				return []byte("Available Packages\n" + pkg + ".x86_64    1.0-1    appstream\n"), nil
			}
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

// A package file that could not be fetched (the error measured on an AlmaLinux e2e host). The module refreshes the
// metadata once and retries; without that, one failed download or a replaced release fails the whole role.
func TestRPMPackageManagers_StaleMetadataRefreshedOnceAndRetried(t *testing.T) {
	stale := "dnf install -y openssh-server: exit status 1: [Errno 2] No such file or directory: " +
		"'/var/cache/dnf/baseos-09b2e93483836b7c/packages/openssh-9.9p1-12.el9_8.alma.1.x86_64.rpm'"
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			var calls []string
			cleaned := false
			impl.module.setRunner(func(ctx context.Context, name string, args ...string) ([]byte, error) {
				calls = append(calls, name+" "+joinArgs(args))
				switch {
				case name == "rpm":
					return nil, exitStatus(1)
				case args[0] == "clean":
					cleaned = true
					return nil, nil
				case args[0] == "install" && !cleaned:
					return nil, fmt.Errorf("%s", stale)
				}
				return nil, nil
			})
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"openssh-server"}}, false)
			if err != nil {
				t.Fatalf("Run: %v (calls %v)", err, calls)
			}
			if !res.Changed {
				t.Error("expected changed=true")
			}
			want := []string{impl.binary + " install -y openssh-server", impl.binary + " clean metadata",
				impl.binary + " install -y openssh-server"}
			got := []string{}
			for _, c := range calls {
				if !strings.HasPrefix(c, "rpm ") {
					got = append(got, c)
				}
			}
			if strings.Join(got, "|") != strings.Join(want, "|") {
				t.Errorf("calls = %v, want %v", got, want)
			}
		})
	}
}

// Only stale metadata earns a retry: "no match" is the operator's typo, and a second stale failure is reported with
// the fact that a refresh was already tried.
func TestRPMPackageManagers_RetryOnlyOnceAndOnlyForStaleMetadata(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			n := 0
			impl.module.setRunner(func(ctx context.Context, name string, args ...string) ([]byte, error) {
				if name == "rpm" {
					return nil, exitStatus(1)
				}
				n++
				return nil, fmt.Errorf("Error: Unable to find a match: httpdd")
			})
			if _, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpdd"}}, false); err == nil {
				t.Fatal("expected an error")
			}
			if n != 1 {
				t.Errorf("a non-stale failure ran %d commands, want 1 (no retry)", n)
			}
			n = 0
			impl.module.setRunner(func(ctx context.Context, name string, args ...string) ([]byte, error) {
				if name == "rpm" {
					return nil, exitStatus(1)
				}
				n++
				if args[0] == "clean" {
					return nil, nil
				}
				return nil, fmt.Errorf("Status code: 404 for https://mirror/x.rpm")
			})
			_, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}}, false)
			if err == nil || !strings.Contains(err.Error(), "failed again after refreshing") {
				t.Fatalf("err = %v, want the second failure to say a refresh was tried", err)
			}
			if n != 3 {
				t.Errorf("ran %d commands, want 3 (install, clean, install)", n)
			}
		})
	}
}

// A preview fails where the real install would: no enabled repository offers the package.
func TestRPM_DryRunRefusesAPackageNoRepositoryOffers(t *testing.T) {
	for _, impl := range rpmModuleImpls() {
		t.Run(impl.binary, func(t *testing.T) {
			fake := &fakeRPM{installed: map[string]string{}, unavailable: map[string]bool{"scx-scheds": true}}
			impl.module.setRunner(fake.runner(impl.binary))
			_, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"scx-scheds"}, "dry_run": true}, false)
			if err == nil || !strings.Contains(err.Error(), "scx-scheds is not offered by any enabled repository") {
				t.Fatalf("err = %v", err)
			}
			res, err := impl.module.Run(context.Background(), map[string]any{"name": []string{"httpd"}, "dry_run": true}, false)
			if err != nil || res.Data.([]map[string]any)[0]["would_install_version"] != "1.0-1" {
				t.Errorf("err=%v data=%v", err, res.Data)
			}
		})
	}
}
