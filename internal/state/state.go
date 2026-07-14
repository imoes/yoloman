// Package state is the agent-local "the server is a JSON document" store:
// a desired-state Document (a list of resources — v1: config files) that can
// be planned (diff observed → desired), applied (converge + record a
// generation), listed, and rolled back to any earlier generation. It is the
// standalone-host apex of the API: GET the server as JSON, PUT it back, see the
// diff, roll it back — all local, no controller required.
//
// Distinct from desiredstate.Applier (which stores the ONE generation Bossman
// pushed, current+previous): this keeps the full generation history and diffs
// at the resource level, reusing the config codec module to read observed
// values and render desired ones.
package state

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"sync"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// Resource is one managed thing in the state document. v1: type "config"
// (a structured file via the config codec). The fields mirror the config
// module's params.
type Resource struct {
	Type      string         `json:"type"`
	Path      string         `json:"path"`
	Format    string         `json:"format,omitempty"`
	Values    map[string]any `json:"values,omitempty"`
	Separator string         `json:"separator,omitempty"`
	Comment   string         `json:"comment,omitempty"`
	Manage    string         `json:"manage,omitempty"`
}

// Document is the whole desired state: an ordered list of resources.
type Document struct {
	Resources []Resource `json:"resources"`
}

// ResourceChange is one resource's plan entry.
type ResourceChange struct {
	Type   string         `json:"type"`
	Path   string         `json:"path"`
	Action string         `json:"action"` // create | update | noop
	Before map[string]any `json:"before,omitempty"`
	After  map[string]any `json:"after,omitempty"`
	// Changed maps each differing key to [before, after].
	Changed map[string][2]any `json:"changed,omitempty"`
	Error   string            `json:"error,omitempty"`
}

// Plan is the diff of a desired Document against the observed state.
type Plan struct {
	Changes      []ResourceChange `json:"changes"`
	ChangedCount int              `json:"changed_count"`
}

// GenerationMeta is the history-list view of one applied generation.
type GenerationMeta struct {
	Number    int64     `json:"number"`
	AppliedAt time.Time `json:"applied_at"`
	Hash      string    `json:"hash"`
	Resources int       `json:"resources"`
}

type generation struct {
	Number    int64     `json:"number"`
	AppliedAt time.Time `json:"applied_at"`
	Hash      string    `json:"hash"`
	Document  Document  `json:"document"`
}

// Store holds the generation history, persisted atomically.
type Store struct {
	path string
	mu   sync.Mutex
	gens []generation
}

func NewStore(path string) *Store {
	s := &Store{path: path}
	s.load()
	return s
}

func (s *Store) load() {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return
	}
	_ = json.Unmarshal(data, &s.gens)
}

func (s *Store) persist() error {
	data, err := json.MarshalIndent(s.gens, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func docHash(doc Document) string {
	b, _ := json.Marshal(doc)
	sum := sha256.Sum256(b)
	return fmt.Sprintf("%x", sum[:8])
}

func (r Resource) readParams() map[string]any {
	p := map[string]any{"path": r.Path, "format": r.Format}
	if r.Separator != "" {
		p["separator"] = r.Separator
	}
	if r.Comment != "" {
		p["comment"] = r.Comment
	}
	return p
}

func (r Resource) writeParams() map[string]any {
	p := r.readParams()
	p["values"] = r.Values
	if r.Manage != "" {
		p["manage"] = r.Manage
	}
	return p
}

// resultConfig pulls the parsed "config" map out of a config-module Result.
func resultConfig(res modules.Result) map[string]any {
	m, ok := res.Data.(map[string]any)
	if !ok {
		return map[string]any{}
	}
	c, _ := m["config"].(map[string]any)
	if c == nil {
		return map[string]any{}
	}
	return c
}

// planResource diffs one resource: read observed, render desired (dry-run),
// compare.
func planResource(ctx context.Context, reg *modules.Registry, r Resource) ResourceChange {
	rc := ResourceChange{Type: r.Type, Path: r.Path, Action: "noop"}
	mod, ok := reg.Get(r.Type)
	if !ok {
		rc.Error = "unknown resource type " + r.Type
		return rc
	}
	observedRes, err := mod.Run(ctx, r.readParams(), true)
	if err != nil {
		rc.Error = "read: " + err.Error()
		return rc
	}
	desiredRes, err := mod.Run(ctx, r.writeParams(), true) // dry-run render
	if err != nil {
		rc.Error = "render: " + err.Error()
		return rc
	}
	rc.Before = resultConfig(observedRes)
	rc.After = resultConfig(desiredRes)
	rc.Changed = diffMaps(rc.Before, rc.After)
	switch {
	case len(rc.Before) == 0 && len(rc.After) > 0:
		rc.Action = "create"
	case len(rc.Changed) > 0:
		rc.Action = "update"
	}
	return rc
}

// diffMaps returns the top-level keys whose values differ, as [before, after].
func diffMaps(before, after map[string]any) map[string][2]any {
	out := map[string][2]any{}
	seen := map[string]bool{}
	for k, av := range after {
		seen[k] = true
		if bv, ok := before[k]; !ok || !reflect.DeepEqual(bv, av) {
			var b any
			if ok {
				b = bv
			}
			out[k] = [2]any{b, av}
		}
	}
	for k, bv := range before {
		if !seen[k] {
			out[k] = [2]any{bv, nil} // present in observed, absent in desired
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// Plan diffs doc against the current observed state (no mutation).
func (s *Store) Plan(ctx context.Context, reg *modules.Registry, doc Document) Plan {
	p := Plan{}
	for _, r := range doc.Resources {
		rc := planResource(ctx, reg, r)
		if rc.Action != "noop" || rc.Error != "" {
			p.ChangedCount++
		}
		p.Changes = append(p.Changes, rc)
	}
	return p
}

// Apply converges doc: writes each resource for real (unless dryRun), then —
// when anything changed and not a dry run — records a new generation. Returns
// the plan that was executed and the new generation number (0 if none).
func (s *Store) Apply(ctx context.Context, reg *modules.Registry, doc Document, dryRun bool) (Plan, int64, error) {
	plan := s.Plan(ctx, reg, doc)
	if dryRun {
		return plan, 0, nil
	}
	changedAny := false
	for _, r := range doc.Resources {
		mod, ok := reg.Get(r.Type)
		if !ok {
			continue
		}
		res, err := mod.Run(ctx, r.writeParams(), false)
		if err != nil {
			return plan, 0, fmt.Errorf("apply %s %s: %w", r.Type, r.Path, err)
		}
		if res.Changed {
			changedAny = true
		}
	}
	if !changedAny {
		return plan, 0, nil
	}
	return plan, s.record(doc), nil
}

func (s *Store) record(doc Document) int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	var num int64 = 1
	if len(s.gens) > 0 {
		num = s.gens[len(s.gens)-1].Number + 1
	}
	s.gens = append(s.gens, generation{Number: num, AppliedAt: time.Now().UTC(), Hash: docHash(doc), Document: doc})
	_ = s.persist()
	return num
}

// Generations lists the recorded generations, newest first.
func (s *Store) Generations() []GenerationMeta {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]GenerationMeta, 0, len(s.gens))
	for i := len(s.gens) - 1; i >= 0; i-- {
		g := s.gens[i]
		out = append(out, GenerationMeta{Number: g.Number, AppliedAt: g.AppliedAt, Hash: g.Hash, Resources: len(g.Document.Resources)})
	}
	return out
}

// Rollback re-applies generation n's document forward (converge the server back
// to that snapshot's managed values, recorded as a new generation). Returns the
// executed plan and the new generation number.
func (s *Store) Rollback(ctx context.Context, reg *modules.Registry, n int64, dryRun bool) (Plan, int64, error) {
	s.mu.Lock()
	var doc *Document
	for i := range s.gens {
		if s.gens[i].Number == n {
			d := s.gens[i].Document
			doc = &d
			break
		}
	}
	s.mu.Unlock()
	if doc == nil {
		return Plan{}, 0, fmt.Errorf("no such generation %d", n)
	}
	return s.Apply(ctx, reg, *doc, dryRun)
}

// DocumentKeys is a small helper for stable output ordering in tests/consumers.
func DocumentKeys(m map[string]any) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}
