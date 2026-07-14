package modules

import (
	"context"
	"sort"
	"strings"
)

// SetFact mirrors ansible.builtin.set_fact: publish variables into the run for
// later steps to use. The controller (Bossman) substitutes any {{ vars }} in
// the values before the call, then merges this module's returned
// `ansible_facts` into the run's variable namespace (Ansible's own
// ansible_facts return convention) — so a later step's when:/{{ }} sees them
// without a register. Free-form: every parameter except the reserved
// `cacheable` becomes a fact.
type SetFact struct{}

// NewSetFact returns a SetFact module.
func NewSetFact() *SetFact { return &SetFact{} }

func (s *SetFact) Name() string { return "set_fact" }

func (s *SetFact) Description() string {
	return "" +
		"Set variables for the rest of the run (ansible.builtin.set_fact). Pass the facts as " +
		"free-form key: value parameters (values may reference {{ other_vars }}, substituted by " +
		"the controller first). Read-only with respect to the host — it changes only the run's " +
		"variable namespace via the returned ansible_facts. `cacheable` is accepted and ignored.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.set_fact.\n" +
		"- Salt: a `grains.set` (persisted) or a jinja `{% set %}` (transient).\n" +
		"- Chef: `node.default['x'] = ...` / `node.run_state`.\n" +
		"- Puppet: a variable assignment `$x = ...`."
}

func (s *SetFact) InputSchema() map[string]any {
	sc := objectSchema(map[string]any{
		"cacheable": boolProp("Persist across runs (accepted, no-op here).", false),
	})
	// Free-form: any additional key is a fact to set.
	sc["additionalProperties"] = true
	return sc
}

func (s *SetFact) Writes() bool { return false }

func (s *SetFact) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	facts := make(map[string]any, len(params))
	names := make([]string, 0, len(params))
	for k, v := range params {
		// cacheable is set_fact's own option; dry_run is injected by the
		// controller for every module call — neither is a fact to publish.
		if k == "cacheable" || k == "dry_run" {
			continue
		}
		facts[k] = v
		names = append(names, k)
	}
	sort.Strings(names)
	// ansible_facts is what the controller merges into the run's variables.
	return Result{
		Changed: false,
		Msg:     "set facts: " + strings.Join(names, ", "),
		Data:    map[string]any{"ansible_facts": facts},
	}, nil
}
