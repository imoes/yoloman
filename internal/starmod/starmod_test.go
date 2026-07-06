package starmod

import (
	"strings"
	"testing"
)

// A contract-correct module: reads state, respects check_mode via the
// builtins, returns {changed, msg}.
const validModule = `
def main(ctx, params):
    name = params.get("name", "nginx")
    res = ctx.run(["systemctl", "is-active", name])
    active = res.rc == 0
    if active:
        return {"changed": False, "msg": name + " already active"}
    start = ctx.run(["systemctl", "start", name], mutates=True)
    if start.skipped:
        return {"changed": True, "msg": "would start " + name}
    if start.rc != 0:
        fail("failed to start " + name + ": " + start.stderr)
    return {"changed": True, "msg": "started " + name, "data": {"name": name}}
`

func TestValidate_ValidModulePasses(t *testing.T) {
	rep := Validate("valid.star", []byte(validModule), Options{ParamsJSON: []byte(`{"name": "nginx"}`)})
	if !rep.OK {
		t.Fatalf("expected OK, got errors: %+v", rep.Errors)
	}
	if !rep.StubOK {
		t.Fatalf("expected StubOK, got errors: %+v", rep.Errors)
	}
	// The recorder saw the real call the module would make.
	joined := strings.Join(rep.Calls, "\n")
	if !strings.Contains(joined, `"is-active"`) {
		t.Errorf("expected recorded run() call, got: %s", joined)
	}
}

func TestValidate_SyntaxError(t *testing.T) {
	rep := Validate("bad.star", []byte("def main(ctx, params)\n    return {}\n"), Options{})
	if rep.OK {
		t.Fatal("expected parse failure")
	}
	if len(rep.Errors) == 0 || rep.Errors[0].Stage != "parse" {
		t.Fatalf("expected a parse diagnostic, got %+v", rep.Errors)
	}
}

func TestValidate_MissingMain(t *testing.T) {
	rep := Validate("nomain.star", []byte("def helper(x):\n    return x\n"), Options{})
	if rep.OK {
		t.Fatal("expected lint failure for missing main")
	}
	if !hasDiag(rep.Errors, "lint", "missing required function") {
		t.Fatalf("expected missing-main lint, got %+v", rep.Errors)
	}
}

func TestValidate_WrongArity(t *testing.T) {
	rep := Validate("arity.star", []byte("def main(ctx):\n    return {\"changed\": False, \"msg\": \"\"}\n"), Options{})
	if rep.OK {
		t.Fatal("expected lint failure for wrong arity")
	}
	if !hasDiag(rep.Errors, "lint", "exactly 2 parameters") {
		t.Fatalf("expected arity lint, got %+v", rep.Errors)
	}
}

func TestValidate_KwargsRejected(t *testing.T) {
	rep := Validate("kwargs.star", []byte("def main(ctx, **kw):\n    return {\"changed\": False, \"msg\": \"\"}\n"), Options{})
	if rep.OK {
		t.Fatal("expected lint failure for **kwargs")
	}
	if !hasDiag(rep.Errors, "lint", "*args/**kwargs") {
		t.Fatalf("expected kwargs lint, got %+v", rep.Errors)
	}
}

func TestValidate_LoadRejected(t *testing.T) {
	src := "load(\"helpers.star\", \"helper\")\n\ndef main(ctx, params):\n    return {\"changed\": False, \"msg\": \"\"}\n"
	rep := Validate("load.star", []byte(src), Options{})
	if rep.OK {
		t.Fatal("expected lint failure for load()")
	}
	if !hasDiag(rep.Errors, "lint", "load() is not allowed") {
		t.Fatalf("expected load lint, got %+v", rep.Errors)
	}
}

func TestValidate_NonDictResultFailsStub(t *testing.T) {
	rep := Validate("baddict.star", []byte("def main(ctx, params):\n    return \"done\"\n"), Options{})
	if !rep.OK {
		t.Fatalf("parse+lint should pass, got %+v", rep.Errors)
	}
	if rep.StubOK {
		t.Fatal("expected stub failure for non-dict result")
	}
	if !hasDiag(rep.Errors, "stub_run", "must return a dict") {
		t.Fatalf("expected return-shape diagnostic, got %+v", rep.Errors)
	}
}

func TestValidate_MissingChangedKeyFailsStub(t *testing.T) {
	rep := Validate("nochanged.star", []byte("def main(ctx, params):\n    return {\"msg\": \"hi\"}\n"), Options{})
	if rep.StubOK {
		t.Fatal("expected stub failure for missing changed key")
	}
	if !hasDiag(rep.Errors, "stub_run", `"changed"`) {
		t.Fatalf("expected changed-key diagnostic, got %+v", rep.Errors)
	}
}

func TestValidate_UnknownCtxAttrFailsStub(t *testing.T) {
	rep := Validate("attr.star", []byte("def main(ctx, params):\n    ctx.reboot()\n    return {\"changed\": True, \"msg\": \"x\"}\n"), Options{})
	if !rep.OK {
		t.Fatalf("parse+lint should pass, got %+v", rep.Errors)
	}
	if rep.StubOK {
		t.Fatal("expected stub failure for unknown ctx attribute")
	}
}

func TestValidate_RunawayLoopBounded(t *testing.T) {
	src := "def main(ctx, params):\n    x = 0\n    for _ in range(1000000000):\n        x += 1\n    return {\"changed\": False, \"msg\": str(x)}\n"
	rep := Validate("loop.star", []byte(src), Options{MaxSteps: 100_000})
	if rep.StubOK {
		t.Fatal("expected stub failure from the step limit")
	}
}

func TestValidate_CheckModeSkipsMutation(t *testing.T) {
	// A module that fail()s if a mutating run is NOT skipped in check
	// mode proves the stub enforces skipped=True there.
	src := `
def main(ctx, params):
    res = ctx.run(["rm", "-rf", "/tmp/x"], mutates=True)
    if ctx.check_mode and not res.skipped:
        fail("mutating run was not skipped in check_mode")
    return {"changed": True, "msg": "ok"}
`
	rep := Validate("checkmode.star", []byte(src), Options{})
	if !rep.StubOK {
		t.Fatalf("expected StubOK, got %+v", rep.Errors)
	}
}

func hasDiag(diags []Diagnostic, stage, substr string) bool {
	for _, d := range diags {
		if d.Stage == stage && strings.Contains(d.Message, substr) {
			return true
		}
	}
	return false
}
