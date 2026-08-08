package starmodules

import (
	"context"
	"os/exec"
	"testing"
)

// A bash module that reads the stdin JSON contract and emits the stdout one:
// it flips `changed` from dry_run and echoes back a param, proving params reach
// the script on stdin and a JSON result is parsed from stdout.
const bashEcho = `#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
name="$(printf '%s' "$payload" | sed -n 's/.*"who"[: ]*"\([^"]*\)".*/\1/p')"
dry="$(printf '%s' "$payload" | grep -o '"dry_run":[a-z]*' | cut -d: -f2)"
changed=true
[ "$dry" = "true" ] && changed=false
printf '{"changed": %s, "msg": "hello %s", "data": {"dry": %s}}\n' "$changed" "$name" "$dry"
`

func newBashModule(writes, agentWrite bool) *ScriptModule {
	return &ScriptModule{
		fqcn: "test.echo", shortName: "echo", description: "echo",
		writes: writes, agentWrite: agentWrite,
		options:     map[string]any{"who": map[string]any{"type": "str", "required": true}},
		interpreter: "bash", src: []byte(bashEcho), ext: ".sh",
	}
}

func TestScriptModule_BashStdinStdout(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available")
	}
	m := newBashModule(false, true)
	res, err := m.Run(context.Background(), map[string]any{"who": "world"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed {
		t.Errorf("expected changed=true, got %+v", res)
	}
	if res.Msg != "hello world" {
		t.Errorf("expected msg 'hello world', got %q", res.Msg)
	}
}

func TestScriptModule_DryRunPassedThrough(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available")
	}
	m := newBashModule(false, true)
	res, err := m.Run(context.Background(), map[string]any{"who": "x"}, true) // dryRun
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed {
		t.Errorf("dry run must report changed=false, got %+v", res)
	}
}

func TestScriptModule_RequiredParam(t *testing.T) {
	m := newBashModule(false, true)
	if _, err := m.Run(context.Background(), map[string]any{}, false); err == nil {
		t.Fatal("expected error for missing required param 'who'")
	}
}

func TestScriptModule_WriteGateClosed(t *testing.T) {
	m := newBashModule(true /*writes*/, false /*agentWrite*/)
	if _, err := m.Run(context.Background(), map[string]any{"who": "x"}, false); err == nil {
		t.Fatal("a mutating script must be refused when the write gate is closed")
	}
	// A dry run is always allowed (must not mutate).
	if _, err := m.Run(context.Background(), map[string]any{"who": "x"}, true); err != nil {
		t.Fatalf("dry run should be allowed even with the write gate closed: %v", err)
	}
}

func TestScriptModule_NonJSONFallback(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not available")
	}
	m := &ScriptModule{
		fqcn: "test.plain", shortName: "plain", writes: false, agentWrite: true,
		interpreter: "bash", ext: ".sh",
		src: []byte("#!/usr/bin/env bash\ncat >/dev/null\necho plain-output\n"),
	}
	res, err := m.Run(context.Background(), map[string]any{}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Changed || res.Msg != "plain-output" {
		t.Errorf("non-JSON success should map to changed=false msg=stdout, got %+v", res)
	}
}

func TestScriptModule_PythonStdinStdout(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not available")
	}
	py := `import sys, json
req = json.load(sys.stdin)
p = req["params"]
print(json.dumps({"changed": not req["dry_run"], "msg": "py " + p["who"]}))
`
	m := &ScriptModule{
		fqcn: "test.py", shortName: "py", writes: false, agentWrite: true,
		options:     map[string]any{"who": map[string]any{"type": "str", "required": true}},
		interpreter: "python3", ext: ".py", src: []byte(py),
	}
	res, err := m.Run(context.Background(), map[string]any{"who": "z"}, false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !res.Changed || res.Msg != "py z" {
		t.Errorf("unexpected result %+v", res)
	}
}

func TestInterpreterForExt(t *testing.T) {
	cases := map[string]string{".py": "python3", ".sh": "bash", ".bash": "bash", ".rb": "", "": ""}
	for ext, want := range cases {
		if got := interpreterForExt(ext); got != want {
			t.Errorf("interpreterForExt(%q)=%q want %q", ext, got, want)
		}
	}
}
