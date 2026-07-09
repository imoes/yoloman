// Package modules implements ansible.builtin-style system management modules
// natively in Go: same parameter names, idempotent, with a dry-run
// (check_mode) path — but requiring no Ansible installation.
package modules

import (
	"context"
	"fmt"
	"sort"
	"sync"
)

// Result is what every module returns after Run.
type Result struct {
	// Changed reports whether Run altered system state. Read-only modules
	// always report false.
	Changed bool `json:"changed"`
	// Msg is an optional human-readable summary (e.g. an error hint or a
	// description of what changed/would change).
	Msg string `json:"msg,omitempty"`
	// Data carries the module-specific payload: gathered facts, a list of
	// matched files, file content, and so on.
	Data any `json:"data,omitempty"`
}

// Module is implemented by every ansible.builtin-style module.
type Module interface {
	// Name is the module's ansible.builtin-style name, e.g. "file", "setup".
	Name() string
	// Description is a thorough, skill-level explanation of what the module
	// does, its parameters, and its semantics — written so that an AI
	// orchestrator can translate a task from *any* configuration-management
	// format (an Ansible playbook task, a Chef recipe resource, a Puppet
	// manifest type, a Salt state, a Terraform resource/provisioner) into a
	// call to this tool without needing external documentation. See each
	// module's source for the specific cross-tool equivalences documented.
	Description() string
	// InputSchema returns a JSON Schema (draft 2020-12 compatible, as a
	// plain map) describing this module's accepted parameters — names,
	// types, and per-parameter descriptions — so MCP/REST clients get a
	// precise, typed contract rather than relying on prose alone.
	InputSchema() map[string]any
	// Writes reports whether this module can mutate system state. Read-only
	// modules run unconditionally; writing modules are only registered/
	// applied when the global write gate is open.
	Writes() bool
	// Run evaluates params against current system state. When dryRun is
	// true (check_mode), Run must report what would change without
	// changing anything; writing modules honor this, read-only modules
	// ignore it since they never mutate state regardless.
	Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error)
}

// Registry holds the set of modules known to the daemon, keyed by name.
type Registry struct {
	mu      sync.RWMutex
	modules map[string]Module
}

// NewRegistry returns an empty module registry.
func NewRegistry() *Registry {
	return &Registry{modules: map[string]Module{}}
}

// Register adds m to the registry. It returns an error if a module with the
// same name is already registered.
func (r *Registry) Register(m Module) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.modules[m.Name()]; exists {
		return fmt.Errorf("module %q already registered", m.Name())
	}
	r.modules[m.Name()] = m
	return nil
}

// Set adds or replaces m in the registry (unlike Register, it overwrites an
// existing same-named module). Used for live module delivery (Block G3): a
// re-pushed .star module updates the running registry in place.
func (r *Registry) Set(m Module) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.modules[m.Name()] = m
}

// Get returns the module registered under name, if any.
func (r *Registry) Get(name string) (Module, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	m, ok := r.modules[name]
	return m, ok
}

// All returns every registered module, sorted by name for deterministic
// iteration (e.g. when registering MCP tools).
func (r *Registry) All() []Module {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Module, 0, len(r.modules))
	for _, m := range r.modules {
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name() < out[j].Name() })
	return out
}
