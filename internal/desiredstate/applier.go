// Package desiredstate implements the L4 agent-side desired-state store
// (see docs/policy-orchestration-architecture.md §6). Direction: the central
// Bossman controller PUSHES the compiled desired state to the agent via
// POST /api/v1/config/apply (over the existing server→agent mTLS channel);
// the agent NEVER dials out. This keeps the firewall to a single rule
// (Bossman → agent), exactly as the architecture requires ("the controller
// pushes, the agent pulls nothing").
//
// The Applier is the local store the push handler writes into: it verifies
// the pushed generation is newer, keeps the previous generation for
// rollback, and persists atomically so a restart doesn't forget the applied
// generation. This v1 is deliberately non-destructive: it stores + reports
// the desired state but does NOT yet re-apply which checks run (that
// behavioral step is a separate block). Payload-signature verification is a
// documented TODO — Bossman does not sign payloads yet.
package desiredstate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// State is one applied desired-state generation.
type State struct {
	Generation int64           `json:"generation"`
	ConfigHash string          `json:"config_hash"`
	Doc        json.RawMessage `json:"doc"`
	AppliedAt  time.Time       `json:"applied_at"`
}

type persisted struct {
	Current  *State `json:"current"`
	Previous *State `json:"previous"`
}

// Applier stores the pushed desired state locally, with rollback.
type Applier struct {
	path string // JSON persistence file

	mu       sync.Mutex
	current  *State
	previous *State
}

// NewApplier builds an applier persisting to path, loading any previously
// persisted state so an agent restart doesn't forget its applied generation.
func NewApplier(path string) *Applier {
	a := &Applier{path: path}
	a.load()
	return a
}

func (a *Applier) load() {
	data, err := os.ReadFile(a.path)
	if err != nil {
		return // no persisted state yet (first run) — fine
	}
	var p persisted
	if json.Unmarshal(data, &p) == nil {
		a.current, a.previous = p.Current, p.Previous
	}
}

func (a *Applier) persist() error {
	// Atomic write: temp file + rename, so a crash mid-write never leaves a
	// half-written state file.
	data, err := json.MarshalIndent(persisted{Current: a.current, Previous: a.previous}, "", "  ")
	if err != nil {
		return err
	}
	tmp := a.path + ".tmp"
	if err := os.MkdirAll(filepath.Dir(a.path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.path)
}

// Apply stores a pushed generation. It rejects a generation that isn't newer
// than the currently applied one (a stale/replayed push can't downgrade),
// returning applied=false in that case. On a newer generation it rolls the
// current into previous, stores the new one, and persists.
func (a *Applier) Apply(generation int64, configHash string, doc json.RawMessage) (applied bool, err error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.current != nil && generation <= a.current.Generation {
		return false, nil // not newer — idempotent no-op
	}
	a.previous = a.current
	a.current = &State{Generation: generation, ConfigHash: configHash, Doc: doc, AppliedAt: time.Now().UTC()}
	if err := a.persist(); err != nil {
		return false, fmt.Errorf("persisting desired state: %w", err)
	}
	return true, nil
}

// Rollback restores the previous generation as current (kept for the
// behavioral-apply block; unused by the non-destructive v1 store path).
func (a *Applier) Rollback() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.previous == nil {
		return fmt.Errorf("no previous generation to roll back to")
	}
	a.current, a.previous = a.previous, nil
	return a.persist()
}

// Status is the read-only view GET /api/v1/state reports.
type Status struct {
	HasState   bool      `json:"has_state"`
	Generation int64     `json:"generation"`
	ConfigHash string    `json:"config_hash"`
	AppliedAt  time.Time `json:"applied_at"`
}

func (a *Applier) Status() Status {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.current == nil {
		return Status{HasState: false}
	}
	return Status{HasState: true, Generation: a.current.Generation, ConfigHash: a.current.ConfigHash, AppliedAt: a.current.AppliedAt}
}
