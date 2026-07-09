package modules

import (
	"context"
	"strings"
	"testing"
)

func TestQMSnapshot_IdempotentPresent(t *testing.T) {
	listing := "`-> current                                          You are here!\n" +
		" pre-upgrade            2024-06-01 12:00:00     before upgrade\n"
	var created bool
	m := &QMSnapshot{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if args[0] == "listsnapshot" {
			return []byte(listing), nil
		}
		if args[0] == "snapshot" {
			created = true
		}
		return nil, nil
	}}
	// pre-upgrade already exists -> no change.
	res, err := m.Run(context.Background(), map[string]any{"vmid": "100", "snapname": "pre-upgrade", "state": "present"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed || created {
		t.Errorf("present on an existing snapshot must be a no-op (changed=%v created=%v)", res.Changed, created)
	}
}

func TestQMSnapshot_CreatesMissing(t *testing.T) {
	var gotArgs []string
	m := &QMSnapshot{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if args[0] == "listsnapshot" {
			return []byte("`-> current   You are here!\n"), nil
		}
		gotArgs = args
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"vmid": "100", "snapname": "s1", "state": "present", "description": "d", "vmstate": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	joined := strings.Join(gotArgs, " ")
	if !res.Changed || !strings.Contains(joined, "snapshot 100 s1") || !strings.Contains(joined, "--vmstate 1") {
		t.Errorf("expected qm snapshot with vmstate, got changed=%v args=%q", res.Changed, joined)
	}
}

func TestQMSnapshot_DryRunNoMutation(t *testing.T) {
	var mutated bool
	m := &QMSnapshot{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if args[0] == "listsnapshot" {
			return []byte(""), nil
		}
		mutated = true
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"vmid": "100", "snapname": "s1", "state": "present", "dry_run": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed || mutated {
		t.Errorf("dry-run should report would-change without mutating (changed=%v mutated=%v)", res.Changed, mutated)
	}
}

func TestQMMigrate_BuildsCommand(t *testing.T) {
	var gotArgs []string
	m := &QMMigrate{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		gotArgs = args
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"vmid": "100", "target": "pve2", "online": true, "with_local_disks": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	joined := strings.Join(gotArgs, " ")
	if !res.Changed || joined != "migrate 100 pve2 --online --with-local-disks" {
		t.Errorf("unexpected migrate command: %q (changed=%v)", joined, res.Changed)
	}
}

func TestVirshSnapshot_AbsentIdempotent(t *testing.T) {
	m := &VirshSnapshot{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if args[0] == "snapshot-list" {
			return []byte("other-snap\n"), nil
		}
		t.Errorf("must not delete a non-existent snapshot: %v", args)
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"domain": "web01", "snapname": "nope", "state": "absent"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Error("absent on a missing snapshot must be unchanged")
	}
}

func TestVirshMigrate_LiveCommand(t *testing.T) {
	var gotArgs []string
	m := &VirshMigrate{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		gotArgs = args
		return nil, nil
	}}
	res, err := m.Run(context.Background(), map[string]any{"domain": "web01", "dest_uri": "qemu+ssh://node2/system", "live": true}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	joined := strings.Join(gotArgs, " ")
	if !res.Changed || joined != "migrate --live web01 qemu+ssh://node2/system" {
		t.Errorf("unexpected virsh migrate command: %q", joined)
	}
}

func TestVirtOps_AreWrites(t *testing.T) {
	for _, w := range []Module{NewQMSnapshot(), NewQMMigrate(), NewVirshSnapshot(), NewVirshMigrate()} {
		if !w.Writes() {
			t.Errorf("%s must be a write module", w.Name())
		}
	}
}
