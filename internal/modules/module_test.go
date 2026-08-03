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

// A duplicate registration must be REFUSED, leaving the first module in place. The whole builtin-catalog
// story rests on this: natives are registered before the embedded/discovered Starlark ones, so for the three
// names that exist twice (dnf, yum, timezone) it is the NATIVE module that runs — which is why Bossman's
// catalog lets a native sidecar win the short name (scripts/generate_builtin_sidecars.py,
// module_library.list_modules). If Register ever started overwriting, the UI would show a form whose fields
// the running module does not accept.
func TestRegister_RefusesDuplicateSoTheFirstWins(t *testing.T) {
	reg := NewRegistry()
	// Same name, different Writes() — that is enough to tell which instance is in the registry.
	first := stubModule{name: "dnf", writes: true}
	second := stubModule{name: "dnf", writes: false}

	if err := reg.Register(first); err != nil {
		t.Fatalf("registering the first module: %v", err)
	}
	if err := reg.Register(second); err == nil {
		t.Fatal("expected the duplicate registration to be refused")
	}
	got, ok := reg.Get("dnf")
	if !ok {
		t.Fatal("dnf disappeared from the registry")
	}
	if !got.Writes() {
		t.Error("the duplicate replaced the original: Writes() = false, want the first module's true")
	}
	// Set() is the explicit override used for live module delivery, and must still replace.
	reg.Set(second)
	if got, _ := reg.Get("dnf"); got.Writes() {
		t.Error("Set() must overwrite, unlike Register()")
	}
}
