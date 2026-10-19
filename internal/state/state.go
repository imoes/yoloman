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
	"bytes"
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
	// Template (Block K2): for Type "template_render", the inline Jinja2 source
	// rendered against Values into Path. Class-B configs (whole file derived
	// from high-level values) managed through the same document loop as codecs.
	Template string `json:"template,omitempty"`
}

// Document is the whole desired state: an ordered list of resources.
type Document struct {
	Resources []Resource `json:"resources"`
}

// ResourceChange is one resource's plan entry.
type ResourceChange struct {
	Type   string         `json:"type"`
	Path   string         `json:"path"`
	Action string         `json:"action"` // create | update | delete (rollback only) | noop
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

// maxGenerations caps the retained configuration history: only the newest N
// generations are kept (oldest pruned on record). Generation Numbers stay
// monotonic; you can roll back to any of the last maxGenerations snapshots.
const maxGenerations = 30

// GenerationMeta is the history-list view of one applied generation.
type GenerationMeta struct {
	Number    int64     `json:"number"`
	AppliedAt time.Time `json:"applied_at"`
	Hash      string    `json:"hash"`
	Resources int       `json:"resources"`
	// Files are the files this generation changed (its before-images).
	Files []string `json:"files"`
	// Note says what produced the generation when it was not a plain apply
	// ("rollback to #3").
	Note string `json:"note,omitempty"`
}

// A GENERATION IS THE HOST'S MANAGED CONFIG AFTER AN APPLY — one meaning,
// host-wide. Each apply sends only the file(s) it edits, so a generation's
// Document is a delta; re-applying generation N's Document (the first
// design) therefore re-wrote only N's own file and reverted nothing that a
// later generation changed elsewhere ("No changes — the host already matches
// #N" while redis.conf stayed edited). Instead every generation records the
// BEFORE-image of each file it changed, and rolling back to N restores, for
// every file a generation after N touched, the content it had before the
// first of those generations — i.e. exactly the host's managed config as it
// stood when N was current. A rollback is recorded as a generation itself
// (with its own before-images), so it can be rolled back too.

// FileState is one file's content at one point in time.
type FileState struct {
	Path    string      `json:"path"`
	Exists  bool        `json:"exists"`
	Content []byte      `json:"content,omitempty"`
	Mode    os.FileMode `json:"mode,omitempty"`
	// TooLarge: the file exceeded maxSnapshotBytes, so no content was kept;
	// a rollback past this generation refuses with that reason.
	TooLarge bool `json:"too_large,omitempty"`
	// Format/Separator/Comment let a rollback preview show the per-key diff.
	Format    string `json:"format,omitempty"`
	Separator string `json:"separator,omitempty"`
	Comment   string `json:"comment,omitempty"`
}

// maxSnapshotBytes bounds one before-image (any real /etc config fits).
const maxSnapshotBytes = 1 << 20

type generation struct {
	Number    int64     `json:"number"`
	AppliedAt time.Time `json:"applied_at"`
	Hash      string    `json:"hash"`
	Document  Document  `json:"document"`
	// Before holds the before-image of every file this generation changed.
	// nil on generations recorded before before-images existed.
	Before []FileState `json:"before,omitempty"`
	Note   string      `json:"note,omitempty"`
}

// snapshotFile reads path's current content as a before-image.
func snapshotFile(r Resource) FileState {
	fs := FileState{Path: r.Path, Format: r.Format, Separator: r.Separator, Comment: r.Comment}
	fi, err := os.Stat(r.Path)
	if err != nil || fi.IsDir() {
		return fs
	}
	fs.Exists, fs.Mode = true, fi.Mode().Perm()
	if fi.Size() > maxSnapshotBytes {
		fs.TooLarge = true
		return fs
	}
	if b, err := os.ReadFile(r.Path); err == nil {
		fs.Content = b
	} else {
		fs.TooLarge = true // unreadable: no image to restore from — refuse later, with the reason
	}
	return fs
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
	if r.Type == "template_render" {
		// Class-B: render the inline template against Values into Path (dest).
		return map[string]any{"template": r.Template, "dest": r.Path, "values": r.Values}
	}
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
	// Template-rendered (Class-B) resource: whole-file text, not per-key values.
	// A dry-run render reports whether the file would change; the detailed text
	// diff is shown client-side. Skip the config-codec read/diff below.
	if r.Type == "template_render" {
		res, rerr := mod.Run(ctx, r.writeParams(), true)
		if rerr != nil {
			rc.Error = "render: " + rerr.Error()
			return rc
		}
		if _, statErr := os.Stat(r.Path); statErr != nil {
			rc.Action = "create"
		} else if res.Changed {
			rc.Action = "update"
		}
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
	var before []FileState
	touched := map[string]bool{}
	for _, r := range doc.Resources {
		mod, ok := reg.Get(r.Type)
		if !ok {
			continue
		}
		img := snapshotFile(r)
		res, err := mod.Run(ctx, r.writeParams(), false)
		if err != nil {
			// What was already written is recorded, not lost: it stays rollback-able.
			if len(before) > 0 {
				s.recordWith(doc, before, "partial apply: "+err.Error())
			}
			return plan, 0, fmt.Errorf("apply %s %s: %w", r.Type, r.Path, err)
		}
		if res.Changed && !touched[r.Path] {
			touched[r.Path] = true
			before = append(before, img)
		}
	}
	if len(before) == 0 {
		return plan, 0, nil
	}
	return plan, s.recordWith(doc, before, ""), nil
}

// record stores doc as a new generation without before-images (tests and
// callers that wrote nothing themselves).
func (s *Store) record(doc Document) int64 { return s.recordWith(doc, nil, "") }

func (s *Store) recordWith(doc Document, before []FileState, note string) int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	var num int64 = 1
	if len(s.gens) > 0 {
		num = s.gens[len(s.gens)-1].Number + 1
	}
	s.gens = append(s.gens, generation{Number: num, AppliedAt: time.Now().UTC(), Hash: docHash(doc), Document: doc,
		Before: before, Note: note})
	// Retention: keep only the newest maxGenerations (drop the oldest).
	if len(s.gens) > maxGenerations {
		s.gens = append([]generation(nil), s.gens[len(s.gens)-maxGenerations:]...)
	}
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
		files := make([]string, 0, len(g.Before))
		for _, b := range g.Before {
			files = append(files, b.Path)
		}
		if g.Before == nil { // recorded before before-images: name what the document targeted
			for _, r := range g.Document.Resources {
				files = append(files, r.Path)
			}
		}
		out = append(out, GenerationMeta{Number: g.Number, AppliedAt: g.AppliedAt, Hash: g.Hash,
			Resources: len(g.Document.Resources), Files: files, Note: g.Note})
	}
	return out
}

// Rollback returns the host's managed config to how it stood when generation
// n was current: every file a LATER generation changed gets back the content
// it had before the first of those generations (see FileState). The plan lists
// one entry per such file; a file whose before-image is missing (too large,
// or a generation recorded before before-images existed) makes the whole
// rollback refuse with that reason — a partial rollback would not be
// "generation n". Applied, it is recorded as a new generation.
func (s *Store) Rollback(ctx context.Context, reg *modules.Registry, n int64, dryRun bool) (Plan, int64, error) {
	s.mu.Lock()
	idx := -1
	for i := range s.gens {
		if s.gens[i].Number == n {
			idx = i
			break
		}
	}
	if idx < 0 {
		s.mu.Unlock()
		return Plan{}, 0, fmt.Errorf("no such generation %d", n)
	}
	var targets []FileState
	var origin []int64
	seen := map[string]bool{}
	type gap struct {
		path string
		gen  int64
	}
	var missing []gap
	for j := idx + 1; j < len(s.gens); j++ {
		g := s.gens[j]
		if g.Before == nil {
			for _, r := range g.Document.Resources {
				if !seen[r.Path] {
					missing = append(missing, gap{r.Path, g.Number})
				}
			}
			continue
		}
		for _, b := range g.Before {
			if seen[b.Path] {
				continue
			}
			seen[b.Path] = true
			targets = append(targets, b)
			origin = append(origin, g.Number)
		}
	}
	s.mu.Unlock()

	plan := Plan{}
	for i, t := range targets {
		rc := planRestore(ctx, reg, t)
		if t.TooLarge {
			rc.Error = fmt.Sprintf("no before-image: the file was larger than %d bytes or unreadable when generation #%d changed it", maxSnapshotBytes, origin[i])
		}
		if rc.Action != "noop" || rc.Error != "" {
			plan.ChangedCount++
		}
		plan.Changes = append(plan.Changes, rc)
	}
	for _, m := range missing {
		plan.Changes = append(plan.Changes, ResourceChange{Type: "file", Path: m.path, Action: "noop",
			Error: fmt.Sprintf("cannot be reverted: generation #%d was recorded before generations kept a before-image", m.gen)})
		plan.ChangedCount++
	}
	if dryRun {
		return plan, 0, nil
	}
	for _, c := range plan.Changes {
		if c.Error != "" {
			return plan, 0, fmt.Errorf("rollback to #%d refused — %s: %s", n, c.Path, c.Error)
		}
	}
	var before []FileState
	doc := Document{}
	for i, t := range targets {
		if plan.Changes[i].Action == "noop" {
			continue
		}
		before = append(before, snapshotFile(Resource{Path: t.Path, Format: t.Format, Separator: t.Separator, Comment: t.Comment}))
		if err := restoreFile(t); err != nil {
			if len(before) > 1 {
				s.recordWith(doc, before[:len(before)-1], fmt.Sprintf("partial rollback to #%d: %v", n, err))
			}
			return plan, 0, fmt.Errorf("rollback %s: %w", t.Path, err)
		}
		doc.Resources = append(doc.Resources, Resource{Type: "file", Path: t.Path})
	}
	if len(before) == 0 {
		return plan, 0, nil
	}
	return plan, s.recordWith(doc, before, fmt.Sprintf("rollback to #%d", n)), nil
}

// planRestore diffs a file's current content against a before-image. With a
// codec format the per-key change is shown (both sides parsed by the config
// module); otherwise the action alone.
func planRestore(ctx context.Context, reg *modules.Registry, t FileState) ResourceChange {
	rc := ResourceChange{Type: "file", Path: t.Path, Action: "noop"}
	cur := snapshotFile(Resource{Path: t.Path})
	switch {
	case t.TooLarge:
		return rc
	case !t.Exists && !cur.Exists:
		return rc
	case !t.Exists:
		rc.Action = "delete"
		return rc
	case !cur.Exists:
		rc.Action = "create"
	case !cur.TooLarge && bytes.Equal(cur.Content, t.Content):
		return rc
	default:
		rc.Action = "update"
	}
	if t.Format == "" {
		return rc
	}
	mod, ok := reg.Get("config")
	if !ok {
		return rc
	}
	r := Resource{Type: "config", Path: t.Path, Format: t.Format, Separator: t.Separator, Comment: t.Comment}
	if cur.Exists {
		if res, err := mod.Run(ctx, r.readParams(), true); err == nil {
			rc.Before = resultConfig(res)
		}
	}
	// Parse the before-image through the same codec from a scratch copy.
	tmp, err := os.CreateTemp("", "state-rollback-*"+filepath.Ext(t.Path))
	if err != nil {
		return rc
	}
	defer os.Remove(tmp.Name())
	_, werr := tmp.Write(t.Content)
	tmp.Close()
	if werr != nil {
		return rc
	}
	r.Path = tmp.Name()
	if res, err := mod.Run(ctx, r.readParams(), true); err == nil {
		rc.After = resultConfig(res)
	}
	rc.Changed = diffMaps(rc.Before, rc.After)
	return rc
}

// restoreFile puts a before-image back: deletes a file that did not exist,
// otherwise writes the content in place (an existing file keeps its owner and
// mode; a re-created one gets the recorded mode).
func restoreFile(t FileState) error {
	if !t.Exists {
		if err := os.Remove(t.Path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	mode := t.Mode
	if mode == 0 {
		mode = 0o644
	}
	if err := os.MkdirAll(filepath.Dir(t.Path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(t.Path, t.Content, mode)
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
