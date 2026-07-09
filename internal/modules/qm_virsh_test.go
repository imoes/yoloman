package modules

import (
	"context"
	"testing"
)

func TestQM_IdempotentStart(t *testing.T) {
	var calls [][]string
	m := &QM{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, append([]string{name}, args...))
		if args[0] == "status" {
			return []byte("status: running\n"), nil
		}
		return nil, nil
	}}
	// Already running -> started is a no-op.
	res, err := m.Run(context.Background(), map[string]any{"vmid": "100", "state": "started"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("started on a running VM must be unchanged")
	}
	for _, c := range calls {
		if len(c) >= 2 && c[1] == "start" {
			t.Errorf("must not call qm start when already running: %v", calls)
		}
	}
}

func TestQM_StopsRunningVM(t *testing.T) {
	var started bool
	m := &QM{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if args[0] == "status" {
			return []byte("status: running\n"), nil
		}
		if args[0] == "stop" {
			started = true
		}
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"vmid": "100", "state": "stopped"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed || !started {
		t.Errorf("stopped on a running VM must call qm stop (changed=%v, stop-called=%v)", res.Changed, started)
	}
}

func TestQM_DryRunNoMutation(t *testing.T) {
	var mutated bool
	m := &QM{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if args[0] == "status" {
			return []byte("status: stopped\n"), nil
		}
		mutated = true
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"vmid": "100", "state": "started", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("dry-run should still report would-change")
	}
	if mutated {
		t.Error("dry-run must not issue qm start")
	}
}

func TestVirsh_ShutdownRunningDomain(t *testing.T) {
	var action string
	m := &Virsh{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if args[0] == "domstate" {
			return []byte("running\n"), nil
		}
		action = args[0]
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"domain": "web01", "state": "shutdown"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed || action != "shutdown" {
		t.Errorf("shutdown on a running domain must call virsh shutdown (changed=%v, action=%q)", res.Changed, action)
	}
}

func TestVirsh_IdempotentStopped(t *testing.T) {
	m := &Virsh{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if args[0] == "domstate" {
			return []byte("shut off\n"), nil
		}
		t.Errorf("must not mutate an already-off domain: %s %v", name, args)
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"domain": "web01", "state": "stopped"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("stopped on an already-off domain must be unchanged")
	}
}

func TestQMVirsh_AreWrites(t *testing.T) {
	if !NewQM().Writes() || !NewVirsh().Writes() {
		t.Error("qm and virsh must be write modules")
	}
}
