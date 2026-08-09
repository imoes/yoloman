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
		{"block succeeded", "ok", "succeeded", "ok,ok,ok"}, // block, always, after
		{"block failed", "boom", "failed", "boom,ok"},      // block, always — then abort
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

// ---- what counts as failure / as a change -------------------------------------------------------
//
// These three keywords change EXECUTION, so each needs its own pin. `ignore_errors` was already
// expressible in the canonical document while the runner ignored it — the worst kind of gap, because the
// document said one thing and the run did another.

// dataModule succeeds but reports a payload — the shape a module like `command` has, which deliberately
// returns a non-zero exit as DATA rather than as an error.
type dataModule struct {
	name  string
	data  map[string]any
	trace *[]string
}

func (m *dataModule) Name() string        { return m.name }
func (m *dataModule) Description() string { return m.name }
func (m *dataModule) InputSchema() map[string]any {
	return map[string]any{"type": "object", "properties": map[string]any{}}
}
func (m *dataModule) Writes() bool { return false }
func (m *dataModule) Run(_ context.Context, _ map[string]any, _ bool) (modules.Result, error) {
	*m.trace = append(*m.trace, m.name)
	return modules.Result{Changed: false, Msg: "executed", Data: m.data}, nil
}

func TestFailedWhenTurnsAModuleResultIntoAFailure(t *testing.T) {
	var trace []string
	reg := regWith(&trace)
	_ = reg.Register(&dataModule{name: "rc1", data: map[string]any{"rc": 1}, trace: &trace})
	rb := Runbook{Name: "fw", Steps: []Step{
		{Name: "cmd", Module: "rc1", FailedWhen: "rc != 0"},
		step("after", "ok"),
	}}
	res := Run(context.Background(), reg, rb, nil, false)
	if res.Status != "failed" {
		t.Fatalf("status = %q, want failed — failed_when must be able to fail a 'successful' step", res.Status)
	}
	if strings.Join(trace, ",") != "rc1" {
		t.Errorf("ran %v — nothing may run after the step failed_when failed", trace)
	}
}

func TestFailedWhenMakesRescueUsableForACommandLikeModule(t *testing.T) {
	var trace []string
	reg := regWith(&trace)
	_ = reg.Register(&dataModule{name: "rc1", data: map[string]any{"rc": 1}, trace: &trace})
	rb := Runbook{Name: "fw", Steps: []Step{
		{
			Name:   "Risky",
			Block:  []Step{{Name: "cmd", Module: "rc1", FailedWhen: "rc != 0"}},
			Rescue: []Step{step("recover", "ok")},
		},
		step("after", "ok"),
	}}
	res := Run(context.Background(), reg, rb, nil, false)
	if res.Status != "succeeded" {
		t.Fatalf("status = %q, want succeeded (rescue handled it)", res.Status)
	}
	if got := strings.Join(trace, ","); got != "rc1,ok,ok" {
		t.Errorf("ran %q, want the command, then rescue, then the step after the group", got)
	}
}

func TestFailedWhenFalseClearsARealFailureButKeepsTheReason(t *testing.T) {
	var trace []string
	rb := Runbook{Name: "fw", Steps: []Step{
		{Name: "boom", Module: "boom", FailedWhen: "false"},
		step("after", "ok"),
	}}
	res := Run(context.Background(), regWith(&trace), rb, nil, false)
	if res.Status != "succeeded" {
		t.Fatalf("status = %q, want succeeded — failed_when overrides in BOTH directions", res.Status)
	}
	if strings.Join(trace, ",") != "boom,ok" {
		t.Errorf("ran %v, want the run to continue past the cleared failure", trace)
	}
	if !strings.Contains(res.Steps[0].Msg, "boom") {
		t.Errorf("msg = %q — a cleared failure must keep its reason, or the diagnosis is lost", res.Steps[0].Msg)
	}
}

func TestChangedWhenOverridesTheReportedChange(t *testing.T) {
	var trace []string
	reg := regWith(&trace)
	_ = reg.Register(&dataModule{name: "rc0", data: map[string]any{"rc": 0, "stdout": ""}, trace: &trace})
	// `ok` reports changed=true; changed_when:false must make the whole run report no change.
	rb := Runbook{Name: "cw", Steps: []Step{{Name: "probe", Module: "ok", ChangedWhen: "false"}}}
	if res := Run(context.Background(), reg, rb, nil, false); res.Changed {
		t.Error("changed_when:false must clear the change flag")
	}
	// and the other way: a module that reports no change can be declared changed.
	rb2 := Runbook{Name: "cw2", Steps: []Step{{Name: "probe", Module: "rc0", ChangedWhen: "rc == 0"}}}
	if res := Run(context.Background(), reg, rb2, nil, false); !res.Changed {
		t.Error("changed_when must be able to declare a change the module did not report")
	}
}

func TestIgnoreErrorsRecordsTheFailureWithoutAbortingTheRun(t *testing.T) {
	var trace []string
	rb := Runbook{Name: "ie", Steps: []Step{
		{Name: "optional", Module: "boom", IgnoreErrors: true},
		step("after", "ok"),
	}}
	res := Run(context.Background(), regWith(&trace), rb, nil, false)
	if res.Status != "succeeded" {
		t.Fatalf("status = %q, want succeeded", res.Status)
	}
	if got := strings.Join(trace, ","); got != "boom,ok" {
		t.Errorf("ran %q — ignore_errors must let the following steps run", got)
	}
	if !strings.Contains(res.Steps[0].Msg, "ignored error") {
		t.Errorf("msg = %q — a swallowed error must stay visible, or a green run hides a real problem",
			res.Steps[0].Msg)
	}
}
