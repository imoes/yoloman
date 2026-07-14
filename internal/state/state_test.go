package state

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

func reg(t *testing.T) *modules.Registry {
	t.Helper()
	r := modules.NewRegistry()
	if err := r.Register(modules.NewConfig()); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestStatePlanApplyRollback(t *testing.T) {
	dir := t.TempDir()
	conf := filepath.Join(dir, "app.conf")
	os.WriteFile(conf, []byte("a=1\nb=2\n"), 0o644)
	store := NewStore(filepath.Join(dir, "state.json"))
	ctx := context.Background()
	r := reg(t)

	docV1 := Document{Resources: []Resource{{
		Type: "config", Path: conf, Format: "keyvalue", Separator: "=",
		Values: map[string]any{"a": "9", "c": "3"},
	}}}

	// PLAN: should be an update with a=1→9 and c added.
	plan := store.Plan(ctx, r, docV1)
	if plan.ChangedCount != 1 || plan.Changes[0].Action != "update" {
		t.Fatalf("plan = %+v", plan.Changes)
	}
	if plan.Changes[0].Changed["a"] != [2]any{"1", "9"} {
		t.Fatalf("expected a: 1→9, got %v", plan.Changes[0].Changed["a"])
	}

	// APPLY → generation 1, file changed.
	_, gen1, err := store.Apply(ctx, r, docV1, false)
	if err != nil || gen1 != 1 {
		t.Fatalf("apply1 gen=%d err=%v", gen1, err)
	}
	if b, _ := os.ReadFile(conf); string(b) != "a=9\nb=2\nc=3\n" {
		t.Fatalf("after apply1: %q", b)
	}

	// Idempotent: same doc → no new generation.
	_, gen, _ := store.Apply(ctx, r, docV1, false)
	if gen != 0 {
		t.Fatalf("re-apply should be a noop, got gen %d", gen)
	}

	// APPLY v2 → generation 2 (a=9→5).
	docV2 := Document{Resources: []Resource{{
		Type: "config", Path: conf, Format: "keyvalue", Separator: "=",
		Values: map[string]any{"a": "5"},
	}}}
	_, gen2, _ := store.Apply(ctx, r, docV2, false)
	if gen2 != 2 {
		t.Fatalf("apply2 gen=%d", gen2)
	}
	if b, _ := os.ReadFile(conf); string(b) != "a=5\nb=2\nc=3\n" {
		t.Fatalf("after apply2: %q", b)
	}

	// Generations history: 2 recorded, newest first.
	if gens := store.Generations(); len(gens) != 2 || gens[0].Number != 2 {
		t.Fatalf("generations = %+v", gens)
	}

	// ROLLBACK to generation 1 → re-applies a=9,c=3 → new generation 3.
	_, gen3, err := store.Rollback(ctx, r, 1, false)
	if err != nil || gen3 != 3 {
		t.Fatalf("rollback gen=%d err=%v", gen3, err)
	}
	if b, _ := os.ReadFile(conf); string(b) != "a=9\nb=2\nc=3\n" {
		t.Fatalf("after rollback to gen1: %q (want a=9)", b)
	}
}
