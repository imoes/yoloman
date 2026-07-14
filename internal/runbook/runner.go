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
	for i, step := range rb.Steps {
		items, err := resolveLoop(step.Loop, vars)
		if err != nil {
			out.Steps = append(out.Steps, StepResult{Index: i, Name: step.Name, Error: err.Error()})
			out.Status = "failed"
			return out
		}
		for _, item := range items {
			sctx := vars
			label := step.Name
			if step.Loop != nil {
				sctx = cloneWith(vars, "item", item)
				label = fmt.Sprintf("%s [item=%v]", step.Name, item)
			}

			if step.When != "" {
				ok, werr := evalWhen(step.When, sctx)
				if werr != nil {
					out.Steps = append(out.Steps, StepResult{Index: i, Name: label, Error: werr.Error()})
					out.Status = "failed"
					return out
				}
				if !ok {
					out.Steps = append(out.Steps, StepResult{Index: i, Name: label, Skipped: true, Msg: "when: " + step.When + " evaluated false"})
					continue
				}
			}

			res := runOne(ctx, reg, step, sctx, dryRun)
			res.Index = i
			res.Name = label
			out.Steps = append(out.Steps, res)
			if res.Changed {
				out.Changed = true
			}
			if res.Error != "" {
				out.Status = "failed"
				return out
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
	return out
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

func resolveLoop(loop any, vars map[string]any) ([]any, error) {
	if loop == nil {
		return []any{nil}, nil
	}
	switch l := loop.(type) {
	case []any:
		return l, nil
	case string:
		v, ok := resolvePath(l, vars)
		if !ok {
			return nil, fmt.Errorf("loop: %q is not defined", l)
		}
		list, ok := v.([]any)
		if !ok {
			return nil, fmt.Errorf("loop: %q did not resolve to a list", l)
		}
		return list, nil
	default:
		return nil, fmt.Errorf("loop must be a list or a dotted-path string")
	}
}

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
