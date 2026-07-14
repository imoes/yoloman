package runbook

import (
	"context"
	"testing"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

func testReg(t *testing.T) *modules.Registry {
	t.Helper()
	r := modules.NewRegistry()
	for _, m := range []modules.Module{modules.NewSetFact(), modules.NewDebug(), modules.NewPing()} {
		if err := r.Register(m); err != nil {
			t.Fatalf("register: %v", err)
		}
	}
	return r
}

func TestRunbookFactFlowAndAssert(t *testing.T) {
	rb := Runbook{
		Name: "t",
		Steps: []Step{
			{Name: "set", Module: "set_fact", Params: map[string]any{"pkg": "nginx", "want": 3}},
			{Name: "say", Module: "debug", Params: map[string]any{"msg": "installing {{ pkg }}"}},
			{Name: "guard", Assert: &AssertSpec{That: []string{"want == 3", "want > 0"}}},
			{Name: "pong", Module: "ping"},
		},
	}
	res := Run(context.Background(), testReg(t), rb, nil, false)
	if res.Status != "succeeded" {
		t.Fatalf("status = %q, steps=%+v", res.Status, res.Steps)
	}
	// debug step must have seen the set fact substituted.
	if res.Steps[1].Msg != "installing nginx" {
		t.Errorf("debug msg = %q, want 'installing nginx'", res.Steps[1].Msg)
	}
	if res.Steps[2].Error != "" {
		t.Errorf("assert should pass, got error %q", res.Steps[2].Error)
	}
}

func TestRunbookWhenSkipAndAssertFail(t *testing.T) {
	rb := Runbook{
		Name: "t",
		Steps: []Step{
			{Name: "skipme", Module: "ping", When: "missing is defined"},
			{Name: "fail here", Assert: &AssertSpec{That: []string{"nope == 'yes'"}, FailMsg: "boom"}},
		},
	}
	res := Run(context.Background(), testReg(t), rb, map[string]any{}, false)
	if !res.Steps[0].Skipped {
		t.Errorf("step 0 should be skipped (when false)")
	}
	if res.Status != "failed" || res.Steps[1].Error != "boom" {
		t.Errorf("assert should fail with 'boom', got status=%q err=%q", res.Status, res.Steps[1].Error)
	}
}

func TestRunbookLoop(t *testing.T) {
	rb := Runbook{
		Name: "t",
		Steps: []Step{
			{Name: "each", Module: "debug", Params: map[string]any{"msg": "pkg {{ item }}"}, Loop: []any{"a", "b"}},
		},
	}
	res := Run(context.Background(), testReg(t), rb, nil, false)
	if res.Status != "succeeded" || len(res.Steps) != 2 {
		t.Fatalf("loop: got %d steps status %q", len(res.Steps), res.Status)
	}
	if res.Steps[0].Msg != "pkg a" || res.Steps[1].Msg != "pkg b" {
		t.Errorf("loop msgs = %q, %q", res.Steps[0].Msg, res.Steps[1].Msg)
	}
}
