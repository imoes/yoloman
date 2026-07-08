package desiredstate

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestApply_StoresNewGeneration(t *testing.T) {
	a := NewApplier(filepath.Join(t.TempDir(), "ds.json"))
	applied, err := a.Apply(3, "h3", json.RawMessage(`{"monitoring":{"checks":["docker_daemon"]}}`))
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if !applied {
		t.Fatal("expected applied=true for first generation")
	}
	st := a.Status()
	if !st.HasState || st.Generation != 3 || st.ConfigHash != "h3" {
		t.Fatalf("status = %+v, want gen 3 / h3", st)
	}
}

func TestApply_RejectsStaleGeneration(t *testing.T) {
	a := NewApplier(filepath.Join(t.TempDir(), "ds.json"))
	if _, err := a.Apply(5, "h5", json.RawMessage(`{}`)); err != nil {
		t.Fatalf("apply gen5: %v", err)
	}
	// A replayed/older push must not downgrade the applied generation.
	applied, err := a.Apply(4, "h4", json.RawMessage(`{}`))
	if err != nil {
		t.Fatalf("apply gen4: %v", err)
	}
	if applied {
		t.Fatal("expected applied=false for a stale (<= current) generation")
	}
	if a.Status().Generation != 5 {
		t.Fatalf("current must stay gen5, got %d", a.Status().Generation)
	}
}

func TestApply_NewerRollsPreviousAndRollback(t *testing.T) {
	a := NewApplier(filepath.Join(t.TempDir(), "ds.json"))
	_, _ = a.Apply(1, "h1", json.RawMessage(`{"v":1}`))
	if _, err := a.Apply(2, "h2", json.RawMessage(`{"v":2}`)); err != nil {
		t.Fatalf("apply gen2: %v", err)
	}
	if a.Status().Generation != 2 {
		t.Fatalf("want current gen2, got %d", a.Status().Generation)
	}
	if err := a.Rollback(); err != nil {
		t.Fatalf("rollback: %v", err)
	}
	if a.Status().Generation != 1 {
		t.Fatalf("after rollback want gen1, got %d", a.Status().Generation)
	}
}

func TestApply_PersistenceSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ds.json")
	a1 := NewApplier(path)
	if _, err := a1.Apply(7, "h7", json.RawMessage(`{}`)); err != nil {
		t.Fatalf("apply: %v", err)
	}
	// A fresh applier over the same file remembers the applied generation.
	a2 := NewApplier(path)
	if a2.Status().Generation != 7 {
		t.Fatalf("restarted applier forgot state: %+v", a2.Status())
	}
}
