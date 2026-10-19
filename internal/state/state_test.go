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

// Configuration history is capped at maxGenerations (30): the oldest are pruned
// while generation Numbers stay monotonic and the newest are always retained.
func TestGenerationRetentionCap(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(filepath.Join(dir, "state.json"))

	var last int64
	for i := 0; i < 35; i++ {
		doc := Document{Resources: []Resource{{
			Type: "config", Path: "/tmp/x", Format: "keyvalue", Separator: "=",
			Values: map[string]any{"n": i},
		}}}
		last = store.record(doc)
	}
	if last != 35 {
		t.Fatalf("last generation number = %d, want 35", last)
	}

	gens := store.Generations() // newest first
	if len(gens) != maxGenerations {
		t.Fatalf("retained %d generations, want %d", len(gens), maxGenerations)
	}
	if gens[0].Number != 35 {
		t.Fatalf("newest generation = %d, want 35", gens[0].Number)
	}
	if gens[len(gens)-1].Number != 6 {
		t.Fatalf("oldest retained generation = %d, want 6 (35-30+1)", gens[len(gens)-1].Number)
	}

	// The cap survives a reload from disk.
	store2 := NewStore(store.path)
	if got := len(store2.Generations()); got != maxGenerations {
		t.Fatalf("after reload: %d generations, want %d", got, maxGenerations)
	}
}

// The defect this design fixes: each apply sends one file, so generation 2
// (redis.conf) and generation 1 (earlyoom) touch different files. Rolling back
// to #1 must revert generation 2's file — not re-apply #1's own file as a noop.
func TestRollbackRevertsLaterGenerationsAcrossFiles(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a.conf")
	b := filepath.Join(dir, "b.conf")
	os.WriteFile(a, []byte("x=1\n"), 0o644)
	os.WriteFile(b, []byte("loglevel=notice\n"), 0o640)
	store := NewStore(filepath.Join(dir, "state.json"))
	ctx := context.Background()
	r := reg(t)
	res := func(path string, v map[string]any) Document {
		return Document{Resources: []Resource{{Type: "config", Path: path, Format: "keyvalue", Separator: "=", Values: v}}}
	}
	if _, g, err := store.Apply(ctx, r, res(a, map[string]any{"x": "2"}), false); err != nil || g != 1 {
		t.Fatalf("gen1 %d %v", g, err)
	}
	if _, g, err := store.Apply(ctx, r, res(b, map[string]any{"loglevel": "verbose"}), false); err != nil || g != 2 {
		t.Fatalf("gen2 %d %v", g, err)
	}
	if gens := store.Generations(); len(gens[0].Files) != 1 || gens[0].Files[0] != b {
		t.Fatalf("generation 2 names the file it changed: %+v", gens[0])
	}

	plan, _, err := store.Rollback(ctx, r, 1, true)
	if err != nil || len(plan.Changes) != 1 || plan.Changes[0].Path != b || plan.Changes[0].Action != "update" {
		t.Fatalf("preview must revert b.conf: %+v err=%v", plan.Changes, err)
	}
	if got := plan.Changes[0].Changed["loglevel"]; got != [2]any{"verbose", "notice"} {
		t.Fatalf("per-key diff, got %v", got)
	}
	_, g3, err := store.Rollback(ctx, r, 1, false)
	if err != nil || g3 != 3 {
		t.Fatalf("rollback gen=%d err=%v", g3, err)
	}
	if got, _ := os.ReadFile(b); string(got) != "loglevel=notice\n" {
		t.Fatalf("b.conf after rollback: %q", got)
	}
	if fi, _ := os.Stat(b); fi.Mode().Perm() != 0o640 {
		t.Fatalf("mode kept, got %v", fi.Mode().Perm())
	}
	if got, _ := os.ReadFile(a); string(got) != "x=2\n" {
		t.Fatalf("a.conf is generation 1's own state and stays: %q", got)
	}
	if gens := store.Generations(); gens[0].Note != "rollback to #1" {
		t.Fatalf("rollback generation carries its note: %+v", gens[0])
	}
	// The rollback is itself a generation: back to #2 re-applies the edit.
	if _, _, err := store.Rollback(ctx, r, 2, false); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(b); string(got) != "loglevel=verbose\n" {
		t.Fatalf("forward again: %q", got)
	}
	// And back to #0-equivalent: rolling back to #1 then to the first state.
	plan, _, _ = store.Rollback(ctx, r, 2, true)
	if plan.ChangedCount != 0 {
		t.Fatalf("host already at #2: %+v", plan.Changes)
	}
}

// A file a generation created is removed again by a rollback before it.
func TestRollbackDeletesFileCreatedLater(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a.conf")
	os.WriteFile(a, []byte("x=1\n"), 0o644)
	n := filepath.Join(dir, "new.conf")
	store := NewStore(filepath.Join(dir, "state.json"))
	ctx := context.Background()
	r := reg(t)
	store.Apply(ctx, r, Document{Resources: []Resource{{Type: "config", Path: a, Format: "keyvalue", Separator: "=", Values: map[string]any{"x": "2"}}}}, false)
	store.Apply(ctx, r, Document{Resources: []Resource{{Type: "config", Path: n, Format: "keyvalue", Separator: "=", Values: map[string]any{"y": "1"}}}}, false)
	if _, err := os.Stat(n); err != nil {
		t.Fatalf("gen2 should create new.conf: %v", err)
	}
	plan, _, _ := store.Rollback(ctx, r, 1, true)
	if len(plan.Changes) != 1 || plan.Changes[0].Action != "delete" {
		t.Fatalf("plan = %+v", plan.Changes)
	}
	if _, _, err := store.Rollback(ctx, r, 1, false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(n); !os.IsNotExist(err) {
		t.Fatalf("new.conf should be gone, stat err=%v", err)
	}
}

// A generation recorded before before-images existed cannot be reverted: the
// rollback refuses and names the file and the generation, instead of
// silently reverting only part of the host.
func TestRollbackRefusesWithoutBeforeImage(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(filepath.Join(dir, "state.json"))
	ctx := context.Background()
	r := reg(t)
	store.record(Document{Resources: []Resource{{Type: "config", Path: "/etc/one"}}})
	store.record(Document{Resources: []Resource{{Type: "config", Path: "/etc/legacy"}}})
	plan, _, err := store.Rollback(ctx, r, 1, true)
	if err != nil || len(plan.Changes) != 1 || plan.Changes[0].Path != "/etc/legacy" || plan.Changes[0].Error == "" {
		t.Fatalf("preview names the gap: %+v err=%v", plan.Changes, err)
	}
	if _, _, err := store.Rollback(ctx, r, 1, false); err == nil {
		t.Fatal("apply must refuse")
	}
}
