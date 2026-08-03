// Package runbook runs an ordered list of steps locally on the agent — the
// standalone-host counterpart to Bossman's plan engine. A runbook is a
// sequence of module calls (plus controller-side assert steps), each with an
// optional when: condition, loop, and register. Steps are evaluated against a
// single variable context (starting params, then each step's registered result
// and any yoloman_facts it publishes), mirroring the Bossman semantics so the
// same runbook runs identically whether driven by the fleet controller or by
// the agent's own /api/v1/runbook/run endpoint.
//
// Deliberately NOT a full plan engine: no OS-family chunk dispatch (a
// standalone agent is one host — condition on ansible facts via when: instead),
// no upload steps. set_fact/debug are ordinary agent modules; assert is the one
// controller-side kind (it reads the run context, which no host module can).
package runbook

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// AssertSpec is a controller-side assertion: every `that` condition (in the
// when-grammar) must hold, else the step fails with FailMsg.
type AssertSpec struct {
	That       []string `json:"that"`
	FailMsg    string   `json:"fail_msg,omitempty"`
	SuccessMsg string   `json:"success_msg,omitempty"`
}

// Step is one runbook step. Exactly one of Module or Assert is set.
type Step struct {
	Name     string         `json:"name"`
	Module   string         `json:"module,omitempty"`
	Params   map[string]any `json:"params,omitempty"`
	Assert   *AssertSpec    `json:"assert,omitempty"`
	When     string         `json:"when,omitempty"`
	Register string         `json:"register,omitempty"`
	// Loop: a literal []any, or a dotted-path string resolving to a list in
	// the context. Each iteration exposes the element as `item`.
	Loop any `json:"loop,omitempty"`

	// Block/Rescue/Always make this step a GROUP — Ansible's block keyword. The group's `When` gates all
	// of its children at once, `Rescue` runs only if the block failed (catch), and `Always` runs whatever
	// happened (finally). A group has no Module of its own.
	Block  []Step `json:"block,omitempty"`
	Rescue []Step `json:"rescue,omitempty"`
	Always []Step `json:"always,omitempty"`
}

// Runbook is a named, ordered list of steps with optional default params.
type Runbook struct {
	Name   string         `json:"name"`
	Params map[string]any `json:"params,omitempty"`
	Steps  []Step         `json:"steps"`
}

// StepResult records one executed (or skipped) step for the run's audit trail.
type StepResult struct {
	Index   int    `json:"index"`
	Name    string `json:"name"`
	Module  string `json:"module,omitempty"`
	Changed bool   `json:"changed"`
	Skipped bool   `json:"skipped,omitempty"`
	Msg     string `json:"msg,omitempty"`
	Data    any    `json:"data,omitempty"`
	Error   string `json:"error,omitempty"`
}

// RunResult is the whole run's outcome.
type RunResult struct {
	Runbook string       `json:"runbook"`
	Status  string       `json:"status"` // "succeeded" | "failed"
	Changed bool         `json:"changed"`
	Steps   []StepResult `json:"steps"`
}

// Run executes rb against reg, seeded with explicit params (merged over the
// runbook's own defaults). dryRun is passed through to every module. It never
// returns an error for a failed step — a failed step is recorded in the result
// and aborts the run (Status "failed"), so the caller always gets a complete
// audit trail.
func Run(ctx context.Context, reg *modules.Registry, rb Runbook, explicit map[string]any, dryRun bool) RunResult {
	vars := map[string]any{}
	for k, v := range rb.Params {
		vars[k] = v
	}
	for k, v := range explicit {
		vars[k] = v
	}

	out := RunResult{Runbook: rb.Name, Status: "succeeded"}
	if runSteps(ctx, reg, rb.Steps, vars, dryRun, &out, "") {
		out.Status = "failed"
	}
	return out
}

/*
runSteps executes one step list and reports whether it FAILED (and therefore stopped).

Returning the failure instead of writing it straight into the result is what makes `block`/`rescue`
possible: a group needs to catch its children's failure, decide whether `rescue` repaired it, and only
then let it propagate. The per-step results stay honest either way — a rescued failure is still recorded
with its error, exactly as Ansible reports it, while the run as a whole continues.

`vars` is shared by reference on purpose: `register` and gathered facts from a step inside a group must be
visible to the steps after it, including outside the group.
*/
func runSteps(ctx context.Context, reg *modules.Registry, steps []Step, vars map[string]any,
	dryRun bool, out *RunResult, prefix string) bool {
	for i, step := range steps {
		items, err := resolveLoop(step.Loop, vars)
		if err != nil {
			out.Steps = append(out.Steps, StepResult{Index: i, Name: prefix + step.Name, Error: err.Error()})
			return true
		}
		for _, item := range items {
			sctx := vars
			label := prefix + step.Name
			if step.Loop != nil {
				sctx = cloneWith(vars, "item", item)
				label = fmt.Sprintf("%s [item=%v]", prefix+step.Name, item)
			}

			if step.When != "" {
				ok, werr := evalWhen(step.When, sctx)
				if werr != nil {
					out.Steps = append(out.Steps, StepResult{Index: i, Name: label, Error: werr.Error()})
					return true
				}
				if !ok {
					out.Steps = append(out.Steps, StepResult{Index: i, Name: label, Skipped: true, Msg: "when: " + step.When + " evaluated false"})
					continue
				}
			}

			// A GROUP (Ansible `block:`) — no module of its own; its children carry the work.
			if len(step.Block) > 0 || len(step.Rescue) > 0 || len(step.Always) > 0 {
				out.Steps = append(out.Steps, StepResult{Index: i, Name: label, Module: "block",
					Msg: fmt.Sprintf("group of %d step(s)", len(step.Block))})
				failed := runSteps(ctx, reg, step.Block, vars, dryRun, out, label+" › ")
				if failed && len(step.Rescue) > 0 {
					// rescue = catch: if it completes, the block's failure is handled and the run goes on.
					failed = runSteps(ctx, reg, step.Rescue, vars, dryRun, out, label+" ⟲ ")
				}
				if len(step.Always) > 0 {
					// always = finally: it runs whatever happened, and its own failure is a real failure.
					if runSteps(ctx, reg, step.Always, vars, dryRun, out, label+" ⤓ ") {
						failed = true
					}
				}
				if failed {
					return true
				}
				continue
			}

			res := runOne(ctx, reg, step, sctx, dryRun)
			res.Index = i
			res.Name = label
			out.Steps = append(out.Steps, res)
			if res.Changed {
				out.Changed = true
			}
			if res.Error != "" {
				return true
			}
			// register + yoloman_facts publish into the shared context.
			if step.Register != "" {
				vars[step.Register] = map[string]any{"changed": res.Changed, "msg": res.Msg, "data": res.Data}
			}
			if facts := extractFacts(res.Data); facts != nil {
				for k, v := range facts {
					vars[k] = v
				}
			}
		}
	}
	return false
}

func runOne(ctx context.Context, reg *modules.Registry, step Step, sctx map[string]any, dryRun bool) StepResult {
	// assert: controller-side — every condition must hold.
	if step.Assert != nil {
		for _, cond := range step.Assert.That {
			ok, err := evalWhen(cond, sctx)
			if err != nil {
				return StepResult{Error: err.Error()}
			}
			if !ok {
				msg := step.Assert.FailMsg
				if msg == "" {
					msg = "assertion failed: " + cond
				}
				return StepResult{Module: "assert", Error: msg}
			}
		}
		msg := step.Assert.SuccessMsg
		if msg == "" {
			msg = "All assertions passed"
		}
		return StepResult{Module: "assert", Msg: msg}
	}

	m, ok := reg.Get(step.Module)
	if !ok {
		return StepResult{Module: step.Module, Error: fmt.Sprintf("unknown module %q", step.Module)}
	}
	body, err := substitute(step.Params, sctx)
	if err != nil {
		return StepResult{Module: step.Module, Error: err.Error()}
	}
	bodyMap, _ := body.(map[string]any)
	if bodyMap == nil {
		bodyMap = map[string]any{}
	}
	r, rerr := m.Run(ctx, bodyMap, dryRun)
	if rerr != nil {
		return StepResult{Module: step.Module, Error: rerr.Error()}
	}
	return StepResult{Module: step.Module, Changed: r.Changed, Msg: r.Msg, Data: r.Data}
}

// extractFacts pulls a module's published yoloman_facts (Result.Data is a
// map carrying "yoloman_facts") — the same convention Bossman merges.
func extractFacts(data any) map[string]any {
	m, ok := data.(map[string]any)
	if !ok {
		return nil
	}
	f, ok := m["yoloman_facts"].(map[string]any)
	if !ok {
		return nil
	}
	return f
}

func cloneWith(base map[string]any, k string, v any) map[string]any {
	out := make(map[string]any, len(base)+1)
	for bk, bv := range base {
		out[bk] = bv
	}
	out[k] = v
	return out
}

// resolveLoop lives in expr.go now (gonja-backed, so `loop: "{{ vols | selectattr(...) }}"` works too).

// numeric coerces a value to float64 for numeric comparisons where possible.
func numeric(v any) (float64, bool) {
	switch n := v.(type) {
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	case float64:
		return n, true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(n), 64)
		return f, err == nil
	default:
		return 0, false
	}
}
