package runbook

import (
	"context"
	"strings"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// Ansible's block semantics are the point here, not the plumbing:
//   - a group's `when` gates ALL its children at once;
//   - `rescue` is catch — if it completes, the block's failure is HANDLED and the run continues;
//   - `always` is finally — it runs whichever way the block went, and its own failure is real;
//   - a failure with no rescue still aborts, and the steps after it do not run.
// The Sequence tree editor emits exactly these, so getting them wrong would silently mis-execute an
// operator's grouped playbook.

// okModule succeeds; failModule fails. Both record that they ran, so a test can assert on ORDER.
type traceModule struct {
	name  string
	fail  bool
	trace *[]string
}

func (m *traceModule) Name() string        { return m.name }
func (m *traceModule) Description() string { return m.name }
func (m *traceModule) InputSchema() map[string]any {
	return map[string]any{"type": "object", "properties": map[string]any{}}
}
func (m *traceModule) Writes() bool { return false }
func (m *traceModule) Run(_ context.Context, _ map[string]any, _ bool) (modules.Result, error) {
	*m.trace = append(*m.trace, m.name)
	if m.fail {
		return modules.Result{}, errNamed("boom")
	}
	return modules.Result{Changed: true, Msg: "ok"}, nil
}

type errNamedT string

func (e errNamedT) Error() string { return string(e) }
func errNamed(s string) error     { return errNamedT(s) }

func regWith(trace *[]string) *modules.Registry {
	reg := modules.NewRegistry()
	_ = reg.Register(&traceModule{name: "ok", trace: trace})
	_ = reg.Register(&traceModule{name: "boom", fail: true, trace: trace})
	return reg
}

func step(name, module string) Step { return Step{Name: name, Module: module} }

func TestBlockRunsItsChildren(t *testing.T) {
	var trace []string
	rb := Runbook{Name: "g", Steps: []Step{
		{Name: "Prepare", Block: []Step{step("a", "ok"), step("b", "ok")}},
		step("after", "ok"),
	}}
	res := Run(context.Background(), regWith(&trace), rb, nil, false)
	if res.Status != "succeeded" {
		t.Fatalf("status = %q, want succeeded (steps: %+v)", res.Status, res.Steps)
	}
	if got := strings.Join(trace, ","); got != "ok,ok,ok" {
		t.Errorf("ran %q, want all three children/steps", got)
	}
}

func TestBlockWhenGatesEveryChild(t *testing.T) {
	var trace []string
	rb := Runbook{Name: "g", Steps: []Step{
		{Name: "Prepare", When: "nope", Block: []Step{step("a", "ok"), step("b", "ok")}},
		step("after", "ok"),
	}}
	res := Run(context.Background(), regWith(&trace), rb, map[string]any{"nope": false}, false)
	if res.Status != "succeeded" {
		t.Fatalf("status = %q, want succeeded", res.Status)
	}
	if len(trace) != 1 {
		t.Errorf("ran %v — a false `when` on the group must skip ALL its children, then continue", trace)
	}
}

func TestRescueHandlesTheFailureAndTheRunContinues(t *testing.T) {
	var trace []string
	rb := Runbook{Name: "g", Steps: []Step{
		{
			Name:   "Install",
			Block:  []Step{step("boom", "boom"), step("never", "ok")},
			Rescue: []Step{step("cleanup", "ok")},
		},
		step("after", "ok"),
	}}
	res := Run(context.Background(), regWith(&trace), rb, nil, false)
	if res.Status != "succeeded" {
		t.Fatalf("status = %q, want succeeded — a completed rescue HANDLES the block's failure", res.Status)
	}
	if got := strings.Join(trace, ","); got != "boom,ok,ok" {
		t.Errorf("ran %q, want boom then rescue then the step after the group (the 2nd block child must be skipped)", got)
	}
	// The failure is still recorded, exactly as Ansible reports a rescued task.
	var sawError bool
	for _, s := range res.Steps {
		if s.Error != "" {
			sawError = true
		}
	}
	if !sawError {
		t.Error("the rescued failure must still appear in the audit trail, not be erased")
	}
}

func TestAlwaysRunsWhetherOrNotTheBlockFailed(t *testing.T) {
	for _, tc := range []struct {
		name       string
		blockMod   string
		wantStatus string
		wantTrace  string
	}{
		{"block succeeded", "ok", "succeeded", "ok,ok,ok"},     // block, always, after
		{"block failed", "boom", "failed", "boom,ok"},          // block, always — then abort
	} {
		t.Run(tc.name, func(t *testing.T) {
			var trace []string
			rb := Runbook{Name: "g", Steps: []Step{
				{Name: "Phase", Block: []Step{step("x", tc.blockMod)}, Always: []Step{step("unmount", "ok")}},
				step("after", "ok"),
			}}
			res := Run(context.Background(), regWith(&trace), rb, nil, false)
			if res.Status != tc.wantStatus {
				t.Errorf("status = %q, want %q", res.Status, tc.wantStatus)
			}
			if got := strings.Join(trace, ","); got != tc.wantTrace {
				t.Errorf("ran %q, want %q", got, tc.wantTrace)
			}
		})
	}
}

func TestAlwaysFailureIsARealFailureEvenWhenTheBlockSucceeded(t *testing.T) {
	var trace []string
	rb := Runbook{Name: "g", Steps: []Step{
		{Name: "Phase", Block: []Step{step("x", "ok")}, Always: []Step{step("teardown", "boom")}},
		step("after", "ok"),
	}}
	res := Run(context.Background(), regWith(&trace), rb, nil, false)
	if res.Status != "failed" {
		t.Errorf("status = %q, want failed — a broken finally is a broken run", res.Status)
	}
	if got := strings.Join(trace, ","); got != "ok,boom" {
		t.Errorf("ran %q, want the block then the failing always, and nothing after", got)
	}
}

func TestAnUnrescuedFailureStillAborts(t *testing.T) {
	var trace []string
	rb := Runbook{Name: "g", Steps: []Step{
		{Name: "Phase", Block: []Step{step("x", "boom")}},
		step("after", "ok"),
	}}
	res := Run(context.Background(), regWith(&trace), rb, nil, false)
	if res.Status != "failed" {
		t.Errorf("status = %q, want failed", res.Status)
	}
	if got := strings.Join(trace, ","); got != "boom" {
		t.Errorf("ran %q — nothing may run after an unrescued failure", got)
	}
}

func TestRegisterInsideAGroupIsVisibleAfterIt(t *testing.T) {
	var trace []string
	rb := Runbook{Name: "g", Steps: []Step{
		{Name: "Phase", Block: []Step{{Name: "probe", Module: "ok", Register: "r"}}},
		{Name: "after", Module: "ok", When: "r.changed"},
	}}
	res := Run(context.Background(), regWith(&trace), rb, nil, false)
	if res.Status != "succeeded" {
		t.Fatalf("status = %q, want succeeded", res.Status)
	}
	if got := strings.Join(trace, ","); got != "ok,ok" {
		t.Errorf("ran %q — a register inside a group must be visible to steps after the group", got)
	}
}

func TestNestedGroups(t *testing.T) {
	var trace []string
	rb := Runbook{Name: "g", Steps: []Step{
		{Name: "outer", Block: []Step{
			{Name: "inner", Block: []Step{step("deep", "ok")}},
			step("sibling", "ok"),
		}},
	}}
	res := Run(context.Background(), regWith(&trace), rb, nil, false)
	if res.Status != "succeeded" || strings.Join(trace, ",") != "ok,ok" {
		t.Errorf("status=%q trace=%v — nested groups must execute depth-first", res.Status, trace)
	}
}
