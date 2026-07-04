package modules

import (
	"context"
	"fmt"
	"testing"
)

func fakeLookPath(available ...string) func(string) (string, error) {
	set := make(map[string]bool, len(available))
	for _, a := range available {
		set[a] = true
	}
	return func(name string) (string, error) {
		if set[name] {
			return "/usr/bin/" + name, nil
		}
		return "", fmt.Errorf("exec: %q: executable file not found in $PATH", name)
	}
}

func TestPackage_DispatchesToAptWhenAvailable(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{}, candidate: map[string]string{"curl": "8.5.0"}}
	p := &Package{LookPath: fakeLookPath("apt-get"), Runner: fake.runner()}
	res, err := p.Run(context.Background(), map[string]any{"name": []string{"curl"}}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true installing via the detected apt-get backend")
	}
	if _, ok := fake.installed["curl"]; !ok {
		t.Error("expected apt-get's install path to have been used")
	}
}

func TestPackage_DispatchesToDnfWhenApNotAvailable(t *testing.T) {
	fake := &fakeRPM{installed: map[string]string{}}
	p := &Package{LookPath: fakeLookPath("dnf"), Runner: fake.runner("dnf")}
	res, err := p.Run(context.Background(), map[string]any{"name": []string{"httpd"}}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true installing via the detected dnf backend")
	}
}

func TestPackage_PrefersAptOverDnfWhenBothPresent(t *testing.T) {
	fake := &fakeApt{installed: map[string]string{}, candidate: map[string]string{"curl": "8.5.0"}}
	p := &Package{LookPath: fakeLookPath("apt-get", "dnf", "yum"), Runner: fake.runner()}
	if _, err := p.Run(context.Background(), map[string]any{"name": []string{"curl"}}, false); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if _, ok := fake.installed["curl"]; !ok {
		t.Error("expected apt-get to be preferred when multiple backends are available")
	}
}

func TestPackage_NoBackendAvailableErrors(t *testing.T) {
	p := &Package{LookPath: fakeLookPath(), Runner: defaultCommandRunner}
	_, err := p.Run(context.Background(), map[string]any{"name": []string{"curl"}}, false)
	if err == nil {
		t.Fatal("expected error when no supported package manager is found")
	}
}
