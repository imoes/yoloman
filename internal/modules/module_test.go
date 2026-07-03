package modules

import (
	"context"
	"testing"
)

type stubModule struct {
	name   string
	writes bool
}

func (s stubModule) Name() string                { return s.name }
func (s stubModule) Description() string         { return "stub" }
func (s stubModule) InputSchema() map[string]any { return objectSchema(map[string]any{}) }
func (s stubModule) Writes() bool                { return s.writes }
func (s stubModule) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	return Result{Changed: false}, nil
}

func TestRegistry_RegisterAndGet(t *testing.T) {
	r := NewRegistry()
	if err := r.Register(stubModule{name: "foo"}); err != nil {
		t.Fatalf("Register: %v", err)
	}
	m, ok := r.Get("foo")
	if !ok {
		t.Fatal("expected to find registered module 'foo'")
	}
	if m.Name() != "foo" {
		t.Errorf("Name() = %q, want foo", m.Name())
	}
}

func TestRegistry_DuplicateNameRejected(t *testing.T) {
	r := NewRegistry()
	if err := r.Register(stubModule{name: "foo"}); err != nil {
		t.Fatalf("Register: %v", err)
	}
	if err := r.Register(stubModule{name: "foo"}); err == nil {
		t.Fatal("expected error registering duplicate module name")
	}
}

func TestRegistry_GetMissing(t *testing.T) {
	r := NewRegistry()
	if _, ok := r.Get("missing"); ok {
		t.Fatal("expected ok=false for unregistered module")
	}
}

func TestRegistry_AllSortedByName(t *testing.T) {
	r := NewRegistry()
	for _, name := range []string{"zeta", "alpha", "mu"} {
		if err := r.Register(stubModule{name: name}); err != nil {
			t.Fatalf("Register(%s): %v", name, err)
		}
	}
	all := r.All()
	if len(all) != 3 {
		t.Fatalf("expected 3 modules, got %d", len(all))
	}
	want := []string{"alpha", "mu", "zeta"}
	for i, m := range all {
		if m.Name() != want[i] {
			t.Errorf("All()[%d] = %q, want %q", i, m.Name(), want[i])
		}
	}
}
