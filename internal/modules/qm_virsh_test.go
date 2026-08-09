package modules

import (
	"context"
	"strings"
	"testing"
)

func TestQM_RunsAnySubcommand(t *testing.T) {
	var gotName string
	var gotArgs []string
	m := &QM{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		gotName, gotArgs = name, args
		return []byte("ok"), nil
	}}
	// A mutating subcommand: snapshot with full arg line.
	res, err := m.Run(context.Background(), map[string]any{
		"command": "snapshot",
		"args":    []any{"100", "pre-upgrade", "--description", "before"},
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if gotName != "qm" || strings.Join(gotArgs, " ") != "snapshot 100 pre-upgrade --description before" {
		t.Errorf("unexpected argv: %s %v", gotName, gotArgs)
	}
	if !res.Changed {
		t.Error("a mutating subcommand must report changed=true")
	}
}

func TestQM_ReadSubcommandRunsEvenInDryRun(t *testing.T) {
	var ran bool
	m := &QM{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		ran = true
		return []byte("status: running\n"), nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"command": "status", "args": []any{"100"}, "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !ran {
		t.Error("a read subcommand (status) must run even under dry_run")
	}
	if res.Changed {
		t.Error("a read subcommand must report changed=false")
	}
	if !strings.Contains(res.Data.(map[string]any)["stdout"].(string), "running") {
		t.Error("stdout should be surfaced for read subcommands")
	}
}

func TestQM_DryRunSkipsMutating(t *testing.T) {
	m := &QM{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		t.Errorf("dry_run must not execute a mutating subcommand: %s %v", name, args)
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"command": "stop", "args": []any{"100"}, "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed || res.Data.(map[string]any)["skipped"] != true {
		t.Errorf("dry_run on a mutating subcommand should report would-change + skipped: %+v", res.Data)
	}
}

func TestQM_RequiresCommand(t *testing.T) {
	m := NewQM()
	if _, err := m.Run(context.Background(), map[string]any{}, false); err == nil {
		t.Error("command is required")
	}
}

func TestVirsh_RunsAnySubcommand(t *testing.T) {
	var gotName string
	var gotArgs []string
	m := &Virsh{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		gotName, gotArgs = name, args
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{
		"command": "migrate",
		"args":    []any{"--live", "web01", "qemu+ssh://node2/system"},
	}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if gotName != "virsh" || strings.Join(gotArgs, " ") != "migrate --live web01 qemu+ssh://node2/system" {
		t.Errorf("unexpected argv: %s %v", gotName, gotArgs)
	}
	if !res.Changed {
		t.Error("mutating subcommand must be changed=true")
	}
}

func TestVirsh_ReadSubcommand(t *testing.T) {
	m := &Virsh{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte("running\n"), nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"command": "domstate", "args": []any{"web01"}}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("domstate is read-only -> changed=false")
	}
}

func TestQMVirsh_AreWrites(t *testing.T) {
	if !NewQM().Writes() || !NewVirsh().Writes() {
		t.Error("qm and virsh must be write modules")
	}
}
