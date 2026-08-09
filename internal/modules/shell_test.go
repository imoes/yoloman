package modules

import (
	"context"
	"errors"
	"testing"
)

func TestShell_PassesCmdExecutableChdirThrough(t *testing.T) {
	var gotScript, gotExecutable, gotChdir string
	s := &Shell{Exec: func(ctx context.Context, script, executable, chdir string) ([]byte, []byte, int, error) {
		gotScript, gotExecutable, gotChdir = script, executable, chdir
		return []byte("out"), []byte(""), 0, nil
	}}
	res, err := s.Run(context.Background(), map[string]any{
		"cmd": "echo hi | tr a-z A-Z", "chdir": "/tmp",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if gotScript != "echo hi | tr a-z A-Z" {
		t.Errorf("script = %q", gotScript)
	}
	if gotExecutable != "/bin/sh" {
		t.Errorf("executable = %q, want default /bin/sh", gotExecutable)
	}
	if gotChdir != "/tmp" {
		t.Errorf("chdir = %q", gotChdir)
	}
	data := res.Data.(map[string]any)
	if data["stdout"] != "out" {
		t.Errorf("stdout = %q", data["stdout"])
	}
}

func TestShell_CustomExecutable(t *testing.T) {
	var gotExecutable string
	s := &Shell{Exec: func(ctx context.Context, script, executable, chdir string) ([]byte, []byte, int, error) {
		gotExecutable = executable
		return nil, nil, 0, nil
	}}
	_, err := s.Run(context.Background(), map[string]any{"cmd": "true", "executable": "/bin/bash"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if gotExecutable != "/bin/bash" {
		t.Errorf("executable = %q, want /bin/bash", gotExecutable)
	}
}

func TestShell_NonZeroExitIsNotAnError(t *testing.T) {
	s := &Shell{Exec: func(ctx context.Context, script, executable, chdir string) ([]byte, []byte, int, error) {
		return nil, []byte("boom"), 3, nil
	}}
	res, err := s.Run(context.Background(), map[string]any{"cmd": "exit 3"}, false)
	if err != nil {
		t.Fatalf("expected no Go error for a non-zero exit, got: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["rc"] != 3 {
		t.Errorf("rc = %v, want 3", data["rc"])
	}
}

func TestShell_StartFailurePropagatesError(t *testing.T) {
	s := &Shell{Exec: func(ctx context.Context, script, executable, chdir string) ([]byte, []byte, int, error) {
		return nil, nil, 0, errors.New("shell not found")
	}}
	_, err := s.Run(context.Background(), map[string]any{"cmd": "true"}, false)
	if err == nil {
		t.Fatal("expected error when the shell fails to start")
	}
}

func TestShell_EmptyCmdRejected(t *testing.T) {
	s := NewShell()
	_, err := s.Run(context.Background(), map[string]any{"cmd": ""}, false)
	if err == nil {
		t.Fatal("expected error for an empty cmd")
	}
}

func TestShell_DryRunDoesNotExecute(t *testing.T) {
	called := false
	s := &Shell{Exec: func(ctx context.Context, script, executable, chdir string) ([]byte, []byte, int, error) {
		called = true
		return nil, nil, 0, nil
	}}
	res, err := s.Run(context.Background(), map[string]any{"cmd": "true", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if called {
		t.Error("expected dry_run to never invoke the shell")
	}
}

// TestShell_RealPipeInterpretation exercises the module against a real
// /bin/sh, proving genuine shell interpretation (a pipe) actually works —
// the entire reason this module exists instead of just using command.
// "echo hi" alone cannot be piped through command's argv-only execution;
// shell must interpret the "|" itself.
func TestShell_RealPipeInterpretation(t *testing.T) {
	s := NewShell()
	res, err := s.Run(context.Background(), map[string]any{"cmd": "echo hello | tr a-z A-Z"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["rc"] != 0 {
		t.Errorf("rc = %v, want 0", data["rc"])
	}
	if data["stdout"] != "HELLO\n" {
		t.Errorf("stdout = %q, want %q (proves the shell, not argv, split and piped this)", data["stdout"], "HELLO\n")
	}
}

// TestShell_RealRedirectAndGlobbing proves redirect + globbing also work —
// syntax command/raw's argv-only model cannot express at all.
func TestShell_RealRedirectAndGlobbing(t *testing.T) {
	dir := t.TempDir()
	s := NewShell()
	res, err := s.Run(context.Background(), map[string]any{
		"cmd":   "echo redirected > out.txt && cat out*.txt",
		"chdir": dir,
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["stdout"] != "redirected\n" {
		t.Errorf("stdout = %q, want %q", data["stdout"], "redirected\n")
	}
}
