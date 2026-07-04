package fleet

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/config"
)

func openTestRegistry(t *testing.T) *SatelliteRegistry {
	t.Helper()
	r, err := OpenRegistry(filepath.Join(t.TempDir(), "satellites.db"))
	if err != nil {
		t.Fatalf("OpenRegistry: %v", err)
	}
	t.Cleanup(func() { r.Close() })
	return r
}

func TestSatelliteRegistry_AddAndList(t *testing.T) {
	r := openTestRegistry(t)
	ctx := context.Background()

	if err := r.Add(ctx, config.Satellite{Name: "sat1", Address: "sat1.example.com:8010", Token: "tok1"}); err != nil {
		t.Fatalf("Add: %v", err)
	}

	sats, err := r.List(ctx)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(sats) != 1 {
		t.Fatalf("expected 1 satellite, got %d", len(sats))
	}
	if sats[0].Name != "sat1" || sats[0].Address != "sat1.example.com:8010" || sats[0].Token != "tok1" {
		t.Errorf("unexpected satellite: %+v", sats[0])
	}
	if sats[0].PollInterval.Duration() != time.Minute {
		t.Errorf("PollInterval = %v, want default 1m", sats[0].PollInterval.Duration())
	}
}

func TestSatelliteRegistry_AddIsIdempotentByName(t *testing.T) {
	r := openTestRegistry(t)
	ctx := context.Background()

	if err := r.Add(ctx, config.Satellite{Name: "sat1", Address: "old.example.com:8010", Token: "old"}); err != nil {
		t.Fatal(err)
	}
	if err := r.Add(ctx, config.Satellite{Name: "sat1", Address: "new.example.com:8010", Token: "new"}); err != nil {
		t.Fatal(err)
	}

	sats, err := r.List(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(sats) != 1 {
		t.Fatalf("expected re-registering the same name to update in place, got %d rows", len(sats))
	}
	if sats[0].Address != "new.example.com:8010" || sats[0].Token != "new" {
		t.Errorf("expected the updated address/token, got %+v", sats[0])
	}
}

func TestSatelliteRegistry_Remove(t *testing.T) {
	r := openTestRegistry(t)
	ctx := context.Background()

	if err := r.Add(ctx, config.Satellite{Name: "sat1", Address: "sat1.example.com:8010"}); err != nil {
		t.Fatal(err)
	}
	if err := r.Remove(ctx, "sat1"); err != nil {
		t.Fatalf("Remove: %v", err)
	}

	sats, err := r.List(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(sats) != 0 {
		t.Errorf("expected no satellites after removal, got %d", len(sats))
	}
}

func TestSatelliteRegistry_RemoveUnknownNameIsNotAnError(t *testing.T) {
	r := openTestRegistry(t)
	if err := r.Remove(context.Background(), "never-existed"); err != nil {
		t.Errorf("expected removing an unknown name to succeed as a no-op, got: %v", err)
	}
}

func TestSatelliteRegistry_AddRejectsEmptyName(t *testing.T) {
	r := openTestRegistry(t)
	if err := r.Add(context.Background(), config.Satellite{Address: "x:8010"}); err == nil {
		t.Fatal("expected error for an empty satellite name")
	}
}

func TestSatelliteRegistry_AddRejectsEmptyAddress(t *testing.T) {
	r := openTestRegistry(t)
	if err := r.Add(context.Background(), config.Satellite{Name: "sat1"}); err == nil {
		t.Fatal("expected error for an empty satellite address")
	}
}

func TestSatelliteRegistry_ListEmpty(t *testing.T) {
	r := openTestRegistry(t)
	sats, err := r.List(context.Background())
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(sats) != 0 {
		t.Errorf("expected no satellites in a fresh registry, got %d", len(sats))
	}
}

func TestSatelliteRegistry_CustomPollIntervalPreserved(t *testing.T) {
	r := openTestRegistry(t)
	ctx := context.Background()

	if err := r.Add(ctx, config.Satellite{
		Name: "sat1", Address: "sat1.example.com:8010", PollInterval: config.Duration(90 * time.Second),
	}); err != nil {
		t.Fatal(err)
	}

	sats, err := r.List(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if sats[0].PollInterval.Duration() != 90*time.Second {
		t.Errorf("PollInterval = %v, want 90s", sats[0].PollInterval.Duration())
	}
}
