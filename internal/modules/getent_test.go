package modules

import (
	"context"
	"errors"
	"testing"
)

func TestGetent_ParsesPasswdOutput(t *testing.T) {
	canned := "root:x:0:0:root:/root:/bin/bash\n" +
		"mutkluge:x:1000:1000:,,,:/home/mutkluge:/bin/bash\n"

	var gotArgs []string
	m := &Getent{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		gotArgs = args
		return []byte(canned), nil
	}}

	res, err := m.Run(context.Background(), map[string]any{"database": "passwd"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(gotArgs) != 1 || gotArgs[0] != "passwd" {
		t.Errorf("unexpected runner args: %v", gotArgs)
	}
	entries := res.Data.([]map[string]any)
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d: %+v", len(entries), entries)
	}
	if entries[0]["name"] != "root" {
		t.Errorf("entries[0][name] = %v, want root", entries[0]["name"])
	}
	fields := entries[1]["fields"].([]string)
	if len(fields) != 7 || fields[0] != "mutkluge" {
		t.Errorf("unexpected fields: %v", fields)
	}
}

func TestGetent_WithKeyPassesItThrough(t *testing.T) {
	var gotArgs []string
	m := &Getent{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		gotArgs = args
		return []byte("root:x:0:0:root:/root:/bin/bash\n"), nil
	}}
	if _, err := m.Run(context.Background(), map[string]any{"database": "passwd", "key": "root"}, false); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(gotArgs) != 2 || gotArgs[0] != "passwd" || gotArgs[1] != "root" {
		t.Errorf("unexpected runner args: %v", gotArgs)
	}
}

func TestGetent_MissingDatabase(t *testing.T) {
	m := NewGetent()
	if _, err := m.Run(context.Background(), map[string]any{}, false); err == nil {
		t.Fatal("expected error for missing database parameter")
	}
}

func TestGetent_RunnerError(t *testing.T) {
	m := &Getent{Runner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return nil, errors.New("getent: not found")
	}}
	if _, err := m.Run(context.Background(), map[string]any{"database": "passwd"}, false); err == nil {
		t.Fatal("expected error to propagate from runner")
	}
}
