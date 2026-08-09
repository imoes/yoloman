package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func newTestSysvinit(t *testing.T, calls *[]string, statusExitCode int) *Sysvinit {
	return &Sysvinit{
		Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			*calls = append(*calls, name+" "+joinArgs(args))
			if len(args) > 0 && args[len(args)-1] == "status" {
				if statusExitCode == 0 {
					return nil, nil
				}
				return nil, exitStatus(statusExitCode)
			}
			return nil, nil
		},
		InitDir: "/etc/init.d",
		RcDirs:  []string{t.TempDir()},
	}
}

func TestSysvinit_StartsWhenNotActive(t *testing.T) {
	var calls []string
	s := newTestSysvinit(t, &calls, 3)
	res, err := s.Run(context.Background(), map[string]any{"name": "myd", "state": "started"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true starting an inactive service")
	}
	found := false
	for _, c := range calls {
		if c == "/etc/init.d/myd start" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a start call, got %v", calls)
	}
}

func TestSysvinit_StartIsIdempotentWhenAlreadyActive(t *testing.T) {
	var calls []string
	s := newTestSysvinit(t, &calls, 0)
	res, err := s.Run(context.Background(), map[string]any{"name": "myd", "state": "started"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when already active")
	}
	for _, c := range calls {
		if c == "/etc/init.d/myd start" {
			t.Error("expected no start call when already active")
		}
	}
}

func TestSysvinit_StopsWhenActive(t *testing.T) {
	var calls []string
	s := newTestSysvinit(t, &calls, 0)
	res, err := s.Run(context.Background(), map[string]any{"name": "myd", "state": "stopped"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true stopping an active service")
	}
}

func TestSysvinit_RestartedAlwaysChanges(t *testing.T) {
	var calls []string
	s := newTestSysvinit(t, &calls, 0)
	res, err := s.Run(context.Background(), map[string]any{"name": "myd", "state": "restarted"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true for restarted")
	}
}

func TestSysvinit_EnabledChecksRcSymlinks(t *testing.T) {
	var calls []string
	s := newTestSysvinit(t, &calls, 0)
	rcDir := s.RcDirs[0]
	if err := os.WriteFile(filepath.Join(rcDir, "S20myd"), []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := s.Run(context.Background(), map[string]any{"name": "myd", "enabled": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("expected changed=false when already enabled")
	}
}

func TestSysvinit_EnabledCallsUpdateRcD(t *testing.T) {
	var calls []string
	s := newTestSysvinit(t, &calls, 0)
	res, err := s.Run(context.Background(), map[string]any{"name": "myd", "enabled": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true enabling a not-yet-enabled service")
	}
	found := false
	for _, c := range calls {
		if c == "update-rc.d myd enable" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected an update-rc.d enable call, got %v", calls)
	}
}

func TestSysvinit_DryRunDoesNotMutate(t *testing.T) {
	var calls []string
	s := newTestSysvinit(t, &calls, 3)
	res, err := s.Run(context.Background(), map[string]any{"name": "myd", "state": "started", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	for _, c := range calls {
		if c == "/etc/init.d/myd start" {
			t.Error("expected dry_run to never issue a start call")
		}
	}
}

func TestSysvinit_InvalidStateRejected(t *testing.T) {
	var calls []string
	s := newTestSysvinit(t, &calls, 0)
	_, err := s.Run(context.Background(), map[string]any{"name": "myd", "state": "bogus"}, false)
	if err == nil {
		t.Fatal("expected error for an invalid state")
	}
}
