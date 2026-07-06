// Package starmod implements the Starlark module contract v1 (see
// docs/plan.md's Block G7/G8): a module is a single .star file defining
//
//	def main(ctx, params):
//	    ...
//	    return {"changed": bool, "msg": str, "data": dict (optional)}
//
// ctx carries the capability-based builtins — the module can only do what
// the agent exposes, and the write gate / dry-run / timeouts are enforced
// INSIDE those builtins, never left to the module author:
//
//	ctx.check_mode          bool — dry-run flag; mutating builtins no-op when set
//	ctx.run(argv, mutates=False, ok_codes=[0])
//	                        → struct(rc, stdout, stderr, skipped)
//	ctx.file_read(path)     → str (fail()s if unreadable)
//	ctx.file_write(path, content, mode=None) → bool changed
//	ctx.file_exists(path)   → bool
//	ctx.stat(path)          → dict | None
//	ctx.facts()             → dict (subset of setup facts)
//
// Failure convention: call fail("message") — Starlark's own builtin.
//
// This package provides the VALIDATOR used by cmd/starlark-check and (via
// that CLI) Bossman's validate_module/submit_module MCP tools: parse +
// contract lint are the hard gate; a stub execution with mocked builtins
// (both check_mode variants) is the soft signal. The real executing
// runtime lands with Block G3; the stub ctx here is deliberately the same
// shape so modules validated today run unchanged then.
package starmod

import (
	"encoding/json"
	"fmt"
	"sort"

	"go.starlark.net/starlark"
	"go.starlark.net/starlarkstruct"
	"go.starlark.net/syntax"
)

// Diagnostic is one validation finding, attributed to a stage.
type Diagnostic struct {
	Stage   string `json:"stage"` // "parse" | "lint" | "stub_run"
	Message string `json:"message"`
	Line    int32  `json:"line,omitempty"`
}

// Report is the structured result of validating one module. OK is the
// hard gate (parse + lint); StubOK is the soft signal (the module also
// survived a mocked execution in both check_mode variants and returned a
// contract-shaped dict).
type Report struct {
	OK       bool         `json:"ok"`
	StubOK   bool         `json:"stub_ok"`
	Errors   []Diagnostic `json:"errors"`
	Warnings []Diagnostic `json:"warnings"`
	// Calls records every ctx.* invocation the stub run observed
	// (e.g. `run(["systemctl", "restart", "nginx"])`) — evidence for a
	// reviewer of what the module would actually do.
	Calls []string `json:"calls,omitempty"`
}

// Options tunes a Validate run.
type Options struct {
	// MaxSteps bounds each stub execution (Starlark computation steps) so
	// a runaway loop cannot hang validation. 0 = the 10M default.
	MaxSteps uint64
	// ParamsJSON is a JSON object with sample params for the stub run.
	// Empty means {}.
	ParamsJSON []byte
}

const defaultMaxSteps = 10_000_000

// Validate runs the full pipeline: parse → contract lint → stub runs.
func Validate(filename string, src []byte, opts Options) Report {
	rep := Report{}

	fileOpts := &syntax.FileOptions{
		// The contract deliberately allows the pragmatic conveniences the
		// agent's real runtime will also enable: set() and reassignment.
		Set:               true,
		GlobalReassign:    true,
		TopLevelControl:   true,
		While:             true,
		Recursion:         false, // no recursion: bounds every module
		LoadBindsGlobally: false,
	}

	f, err := fileOpts.Parse(filename, src, 0)
	if err != nil {
		rep.Errors = append(rep.Errors, parseDiag(err))
		return rep
	}

	lintErrs := lint(f)
	rep.Errors = append(rep.Errors, lintErrs...)
	rep.OK = len(rep.Errors) == 0
	if !rep.OK {
		return rep
	}

	params, err := paramsValue(opts.ParamsJSON)
	if err != nil {
		// Bad sample params are a caller bug, not a module defect — surface
		// as a warning and stub-run with empty params instead.
		rep.Warnings = append(rep.Warnings, Diagnostic{Stage: "stub_run", Message: fmt.Sprintf("invalid params JSON (using {}): %v", err)})
		params = starlark.NewDict(0)
	}

	maxSteps := opts.MaxSteps
	if maxSteps == 0 {
		maxSteps = defaultMaxSteps
	}

	rec := &Recorder{}
	stubOK := true
	// Both dry-run variants: a contract-correct module must survive both.
	for _, checkMode := range []bool{true, false} {
		if diags := stubRun(fileOpts, filename, src, params, checkMode, maxSteps, rec); len(diags) > 0 {
			rep.Errors = append(rep.Errors, diags...)
			stubOK = false
		}
	}
	rep.StubOK = stubOK
	rep.Calls = rec.Calls
	// Stub failures are the soft signal: OK (the hard gate) stays true as
	// long as parse+lint passed — canned stub outputs (rc=0, stdout="")
	// legitimately break modules that parse real command output.
	return rep
}

func parseDiag(err error) Diagnostic {
	d := Diagnostic{Stage: "parse", Message: err.Error()}
	if e, ok := err.(syntax.Error); ok {
		d.Line = e.Pos.Line
	}
	return d
}

// lint enforces the static half of the contract: exactly one
// `def main(ctx, params)` and no load() statements (a module is
// self-contained — its only environment is ctx).
func lint(f *syntax.File) []Diagnostic {
	var diags []Diagnostic
	var mainDef *syntax.DefStmt
	for _, stmt := range f.Stmts {
		switch s := stmt.(type) {
		case *syntax.LoadStmt:
			pos := s.Load
			diags = append(diags, Diagnostic{Stage: "lint", Line: pos.Line,
				Message: "load() is not allowed: a module is self-contained, its only environment is ctx"})
		case *syntax.DefStmt:
			if s.Name.Name == "main" {
				mainDef = s
			}
		}
	}
	if mainDef == nil {
		diags = append(diags, Diagnostic{Stage: "lint",
			Message: "missing required function: def main(ctx, params)"})
		return diags
	}
	// Exactly the two positional contract parameters — no *args/**kwargs
	// (they would hide contract drift) and no extras.
	names := make([]string, 0, len(mainDef.Params))
	for _, p := range mainDef.Params {
		switch e := p.(type) {
		case *syntax.Ident:
			names = append(names, e.Name)
		case *syntax.BinaryExpr: // default value: name=expr
			if id, ok := e.X.(*syntax.Ident); ok {
				names = append(names, id.Name)
			}
		case *syntax.UnaryExpr: // *args / **kwargs
			diags = append(diags, Diagnostic{Stage: "lint", Line: mainDef.Def.Line,
				Message: "main must not use *args/**kwargs — the contract signature is main(ctx, params)"})
			return diags
		}
	}
	if len(names) != 2 {
		diags = append(diags, Diagnostic{Stage: "lint", Line: mainDef.Def.Line,
			Message: fmt.Sprintf("main must take exactly 2 parameters (ctx, params), got %d (%v)", len(names), names)})
	}
	return diags
}

func stubRun(fileOpts *syntax.FileOptions, filename string, src []byte, params starlark.Value, checkMode bool, maxSteps uint64, rec *Recorder) []Diagnostic {
	label := fmt.Sprintf("stub run (check_mode=%v)", checkMode)
	thread := &starlark.Thread{Name: label}
	thread.SetMaxExecutionSteps(maxSteps)

	globals, err := starlark.ExecFileOptions(fileOpts, thread, filename, src, nil)
	if err != nil {
		return []Diagnostic{stubDiag(label+": module top-level failed", err)}
	}
	mainFn, ok := globals["main"]
	if !ok {
		return []Diagnostic{{Stage: "stub_run", Message: label + ": main not exported"}}
	}

	ctx := StubCtx(checkMode, rec)
	res, err := starlark.Call(thread, mainFn, starlark.Tuple{ctx, params}, nil)
	if err != nil {
		return []Diagnostic{stubDiag(label+": main() failed", err)}
	}
	return checkResult(label, res)
}

func stubDiag(prefix string, err error) Diagnostic {
	msg := err.Error()
	if evalErr, ok := err.(*starlark.EvalError); ok {
		msg = evalErr.Backtrace()
	}
	return Diagnostic{Stage: "stub_run", Message: prefix + ": " + msg}
}

// checkResult enforces the return contract: a dict with a bool "changed"
// and a string "msg"; "data", if present, must be a dict.
func checkResult(label string, v starlark.Value) []Diagnostic {
	d, ok := v.(*starlark.Dict)
	if !ok {
		return []Diagnostic{{Stage: "stub_run",
			Message: fmt.Sprintf("%s: main() must return a dict {changed, msg}, got %s", label, v.Type())}}
	}
	var diags []Diagnostic
	changed, found, _ := d.Get(starlark.String("changed"))
	if !found {
		diags = append(diags, Diagnostic{Stage: "stub_run", Message: label + `: result is missing required key "changed" (bool)`})
	} else if _, ok := changed.(starlark.Bool); !ok {
		diags = append(diags, Diagnostic{Stage: "stub_run", Message: fmt.Sprintf(`%s: result "changed" must be a bool, got %s`, label, changed.Type())})
	}
	msg, found, _ := d.Get(starlark.String("msg"))
	if !found {
		diags = append(diags, Diagnostic{Stage: "stub_run", Message: label + `: result is missing required key "msg" (string)`})
	} else if _, ok := msg.(starlark.String); !ok {
		diags = append(diags, Diagnostic{Stage: "stub_run", Message: fmt.Sprintf(`%s: result "msg" must be a string, got %s`, label, msg.Type())})
	}
	if data, found, _ := d.Get(starlark.String("data")); found {
		if _, ok := data.(*starlark.Dict); !ok {
			diags = append(diags, Diagnostic{Stage: "stub_run", Message: fmt.Sprintf(`%s: result "data" must be a dict, got %s`, label, data.Type())})
		}
	}
	return diags
}

// Recorder collects the ctx.* calls a stub run makes.
type Recorder struct {
	Calls []string
}

func (r *Recorder) record(format string, args ...any) {
	if r == nil {
		return
	}
	r.Calls = append(r.Calls, fmt.Sprintf(format, args...))
}

// StubCtx builds the mocked ctx struct handed to main() during
// validation. Same member set as the future real runtime (Block G3) —
// only the implementations are canned.
func StubCtx(checkMode bool, rec *Recorder) *starlarkstruct.Struct {
	members := starlark.StringDict{
		"check_mode": starlark.Bool(checkMode),
		"run": starlark.NewBuiltin("run", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var argv *starlark.List
			var mutates bool
			var okCodes starlark.Value = starlark.None
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "argv", &argv, "mutates?", &mutates, "ok_codes?", &okCodes); err != nil {
				return nil, err
			}
			rec.record("run(%s, mutates=%v)", argv.String(), mutates)
			skipped := checkMode && mutates
			return starlarkstruct.FromStringDict(starlark.String("run_result"), starlark.StringDict{
				"rc":      starlark.MakeInt(0),
				"stdout":  starlark.String(""),
				"stderr":  starlark.String(""),
				"skipped": starlark.Bool(skipped),
			}), nil
		}),
		"file_read": starlark.NewBuiltin("file_read", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var path string
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path); err != nil {
				return nil, err
			}
			rec.record("file_read(%q)", path)
			return starlark.String(""), nil
		}),
		"file_write": starlark.NewBuiltin("file_write", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var path, content string
			var mode starlark.Value = starlark.None
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path, "content", &content, "mode?", &mode); err != nil {
				return nil, err
			}
			rec.record("file_write(%q, %d bytes, check_mode=%v)", path, len(content), checkMode)
			// The real runtime skips the write in check_mode and returns the
			// predicted changed value; the stub predicts "would change".
			return starlark.Bool(true), nil
		}),
		"file_exists": starlark.NewBuiltin("file_exists", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var path string
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path); err != nil {
				return nil, err
			}
			rec.record("file_exists(%q)", path)
			return starlark.False, nil
		}),
		"stat": starlark.NewBuiltin("stat", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var path string
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path); err != nil {
				return nil, err
			}
			rec.record("stat(%q)", path)
			return starlark.None, nil
		}),
		"facts": starlark.NewBuiltin("facts", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			if err := starlark.UnpackArgs(b.Name(), args, kwargs); err != nil {
				return nil, err
			}
			rec.record("facts()")
			facts := starlark.NewDict(4)
			_ = facts.SetKey(starlark.String("os_family"), starlark.String("debian"))
			_ = facts.SetKey(starlark.String("distribution"), starlark.String("debian"))
			_ = facts.SetKey(starlark.String("hostname"), starlark.String("stub-host"))
			_ = facts.SetKey(starlark.String("architecture"), starlark.String("x86_64"))
			return facts, nil
		}),
	}
	return starlarkstruct.FromStringDict(starlark.String("ctx"), members)
}

// paramsValue converts a JSON object into the starlark dict handed to
// main() as params.
func paramsValue(paramsJSON []byte) (starlark.Value, error) {
	if len(paramsJSON) == 0 {
		return starlark.NewDict(0), nil
	}
	var raw map[string]any
	if err := json.Unmarshal(paramsJSON, &raw); err != nil {
		return nil, err
	}
	v, err := goToStarlark(raw)
	if err != nil {
		return nil, err
	}
	return v, nil
}

func goToStarlark(v any) (starlark.Value, error) {
	switch x := v.(type) {
	case nil:
		return starlark.None, nil
	case bool:
		return starlark.Bool(x), nil
	case string:
		return starlark.String(x), nil
	case float64:
		if x == float64(int64(x)) {
			return starlark.MakeInt64(int64(x)), nil
		}
		return starlark.Float(x), nil
	case []any:
		elems := make([]starlark.Value, 0, len(x))
		for _, e := range x {
			sv, err := goToStarlark(e)
			if err != nil {
				return nil, err
			}
			elems = append(elems, sv)
		}
		return starlark.NewList(elems), nil
	case map[string]any:
		d := starlark.NewDict(len(x))
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys) // deterministic iteration for stable stub behavior
		for _, k := range keys {
			sv, err := goToStarlark(x[k])
			if err != nil {
				return nil, err
			}
			if err := d.SetKey(starlark.String(k), sv); err != nil {
				return nil, err
			}
		}
		return d, nil
	default:
		return nil, fmt.Errorf("unsupported params value type %T", v)
	}
}
