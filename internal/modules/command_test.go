package modules

import (
	"context"
	"errors"
	"testing"
)

func TestCommand_RunsArgvAndCapturesOutput(t *testing.T) {
	var gotArgv []string
	var gotChdir string
	c := &Command{Exec: func(ctx context.Context, argv []string, chdir string) ([]byte, []byte, int, error) {
		gotArgv = argv
		gotChdir = chdir
		return []byte("stdout data"), []byte("stderr data"), 0, nil
	}}

	res, err := c.Run(context.Background(), map[string]any{
		"argv":  []string{"echo", "hi"},
		"chdir": "/tmp",
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true after actually executing")
	}
	if len(gotArgv) != 2 || gotArgv[0] != "echo" || gotArgv[1] != "hi" {
		t.Errorf("unexpected argv passed to Exec: %v", gotArgv)
	}
	if gotChdir != "/tmp" {
		t.Errorf("chdir = %q, want /tmp", gotChdir)
	}
	data := res.Data.(map[string]any)
	if data["stdout"] != "stdout data" || data["stderr"] != "stderr data" || data["rc"] != 0 {
		t.Errorf("unexpected data: %+v", data)
	}
}

func TestCommand_CmdSplitsOnWhitespace(t *testing.T) {
	var gotArgv []string
	c := &Command{Exec: func(ctx context.Context, argv []string, chdir string) ([]byte, []byte, int, error) {
		gotArgv = argv
		return nil, nil, 0, nil
	}}
	if _, err := c.Run(context.Background(), map[string]any{"cmd": "systemctl daemon-reload"}, false); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(gotArgv) != 2 || gotArgv[0] != "systemctl" || gotArgv[1] != "daemon-reload" {
		t.Errorf("unexpected argv from cmd split: %v", gotArgv)
	}
}

func TestCommand_NonZeroExitIsNotAnError(t *testing.T) {
	c := &Command{Exec: func(ctx context.Context, argv []string, chdir string) ([]byte, []byte, int, error) {
		return []byte(""), []byte("boom"), 1, nil
	}}
	res, err := c.Run(context.Background(), map[string]any{"argv": []string{"false"}}, false)
	if err != nil {
		t.Fatalf("expected no Go error for non-zero exit, got %v", err)
	}
	data := res.Data.(map[string]any)
	if data["rc"] != 1 {
		t.Errorf("rc = %v, want 1", data["rc"])
	}
}

func TestCommand_ExecStartFailureIsAnError(t *testing.T) {
	c := &Command{Exec: func(ctx context.Context, argv []string, chdir string) ([]byte, []byte, int, error) {
		return nil, nil, 0, errors.New("exec: \"nosuchbinary\": executable file not found in $PATH")
	}}
	if _, err := c.Run(context.Background(), map[string]any{"argv": []string{"nosuchbinary"}}, false); err == nil {
		t.Fatal("expected error when the process fails to start")
	}
}

func TestCommand_DryRunDoesNotExecute(t *testing.T) {
	called := false
	c := &Command{Exec: func(ctx context.Context, argv []string, chdir string) ([]byte, []byte, int, error) {
		called = true
		return nil, nil, 0, nil
	}}
	res, err := c.Run(context.Background(), map[string]any{"argv": []string{"rm", "-rf", "/tmp/whatever"}, "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if called {
		t.Error("expected Exec to not be called under dry_run")
	}
}

func TestCommand_BothCmdAndArgvRejected(t *testing.T) {
	c := NewCommand()
	if _, err := c.Run(context.Background(), map[string]any{"cmd": "ls", "argv": []string{"ls"}}, false); err == nil {
		t.Fatal("expected error when both cmd and argv are given")
	}
}

func TestCommand_NeitherCmdNorArgvRejected(t *testing.T) {
	c := NewCommand()
	if _, err := c.Run(context.Background(), map[string]any{}, false); err == nil {
		t.Fatal("expected error when neither cmd nor argv is given")
	}
}

func TestCommand_RealExecution(t *testing.T) {
	c := NewCommand()
	res, err := c.Run(context.Background(), map[string]any{"argv": []string{"echo", "hello-agentic-mcp"}}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["rc"] != 0 {
		t.Errorf("rc = %v, want 0", data["rc"])
	}
	if got := data["stdout"].(string); got != "hello-agentic-mcp\n" {
		t.Errorf("stdout = %q, want %q", got, "hello-agentic-mcp\n")
	}
}
