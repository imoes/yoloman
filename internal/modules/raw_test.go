package modules

import (
	"context"
	"testing"
)

func TestRaw_RunsLikeCommand(t *testing.T) {
	r := NewRaw()
	res, err := r.Run(context.Background(), map[string]any{"cmd": "/bin/echo hello-from-raw"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	data := res.Data.(map[string]any)
	if data["rc"] != 0 {
		t.Errorf("rc = %v, want 0", data["rc"])
	}
	if data["stdout"] != "hello-from-raw\n" {
		t.Errorf("stdout = %q", data["stdout"])
	}
}

func TestRaw_NameIsRaw(t *testing.T) {
	r := NewRaw()
	if r.Name() != "raw" {
		t.Errorf("Name() = %q, want raw", r.Name())
	}
}

func TestRaw_IsWriting(t *testing.T) {
	r := NewRaw()
	if !r.Writes() {
		t.Error("expected raw to be a writing module, like command")
	}
}

func TestRaw_DryRunDoesNotExecute(t *testing.T) {
	r := NewRaw()
	res, err := r.Run(context.Background(), map[string]any{"cmd": "/bin/true", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Error("expected changed=true (predicted) under dry_run")
	}
}
