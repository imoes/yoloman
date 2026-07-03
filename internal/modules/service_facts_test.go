package modules

import (
	"context"
	"errors"
	"testing"
)

func TestServiceFacts_ParsesSystemctlOutput(t *testing.T) {
	canned := "nginx.service    loaded active running A high performance web server\n" +
		"cron.service     loaded active running Regular background program processing daemon\n" +
		"sshd.service     loaded failed failed  OpenSSH server daemon\n"

	m := &ServiceFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name != "systemctl" {
			t.Errorf("expected systemctl, got %q", name)
		}
		return []byte(canned), nil
	}}

	res, err := m.Run(context.Background(), nil, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	services := res.Data.([]map[string]any)
	if len(services) != 3 {
		t.Fatalf("expected 3 services, got %d: %+v", len(services), services)
	}
	if services[0]["name"] != "nginx" || services[0]["active"] != "active" {
		t.Errorf("unexpected first service: %+v", services[0])
	}
	if services[2]["name"] != "sshd" || services[2]["active"] != "failed" {
		t.Errorf("unexpected third service: %+v", services[2])
	}
}

func TestServiceFacts_RunnerError(t *testing.T) {
	m := &ServiceFacts{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return nil, errors.New("systemctl: command not found")
	}}
	if _, err := m.Run(context.Background(), nil, false); err == nil {
		t.Fatal("expected error to propagate from runner")
	}
}

func TestServiceFacts_IsReadOnly(t *testing.T) {
	m := NewServiceFacts()
	if m.Writes() {
		t.Error("service_facts must be read-only")
	}
}
