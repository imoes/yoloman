package modules

import (
	"context"
	"testing"
)

func TestSystemdService_IsAliasOfSystemd(t *testing.T) {
	fake := &fakeSystemctl{active: false}
	svc := &SystemdService{Systemd: &Systemd{Runner: fake.runner()}}
	if svc.Name() != "systemd_service" {
		t.Errorf("Name() = %q, want systemd_service", svc.Name())
	}
	res, err := svc.Run(context.Background(), map[string]any{"name": "nginx", "state": "started"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed || !fake.active {
		t.Error("expected systemd_service alias to behave like systemd module")
	}
}
