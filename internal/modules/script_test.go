package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestScript_RunsRealScript(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "test.sh")
	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\necho hello from script\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := NewScript()
	res, err := s.Run(context.Background(), map[string]any{"cmd": scriptPath}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (script always reports changed once run)")
	}
	data := res.Data.(map[string]any)
	if data["rc"] != 0 {
		t.Errorf("rc = %v, want 0", data["rc"])
	}
	if data["stdout"] != "hello from script\n" {
		t.Errorf("stdout = %q", data["stdout"])
	}
}

func TestScript_NonZeroExitIsNotAnError(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "fail.sh")
	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\nexit 3\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := NewScript()
	res, err := s.Run(context.Background(), map[string]any{"cmd": scriptPath}, false)
	if err != nil {
		t.Fatalf("expected no Go error for a non-zero exit, got: %v", err)
	}
	if res.Data.(map[string]any)["rc"] != 3 {
		t.Errorf("rc = %v, want 3", res.Data.(map[string]any)["rc"])
	}
}

func TestScript_ArgumentsPassed(t *testing.T) {
	dir := t.TempDir()
	scriptPath := filepath.Join(dir, "args.sh")
	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\necho \"$1 $2\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := NewScript()
	res, err := s.Run(context.Background(), map[string]any{"cmd": scriptPath + " foo bar"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Data.(map[string]any)["stdout"] != "foo bar\n" {
		t.Errorf("stdout = %q", res.Data.(map[string]any)["stdout"])
	}
}

func TestScript_EmptyCmdRejected(t *testing.T) {
	s := NewScript()
	_, err := s.Run(context.Background(), map[string]any{"cmd": "   "}, false)
	if err == nil {
		t.Fatal("expected error for an empty cmd")
	}
}

func TestScript_MissingScriptErrors(t *testing.T) {
	s := NewScript()
	_, err := s.Run(context.Background(), map[string]any{"cmd": "/no/such/script.sh"}, false)
	if err == nil {
		t.Fatal("expected error when the script doesn't exist")
	}
}

func TestScript_DryRunDoesNotExecute(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "ran")
	scriptPath := filepath.Join(dir, "touch.sh")
	if err := os.WriteFile(scriptPath, []byte("#!/bin/sh\ntouch "+marker+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := NewScript()
	res, err := s.Run(context.Background(), map[string]any{"cmd": scriptPath, "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Error("expected dry_run to not actually execute the script")
	}
}
