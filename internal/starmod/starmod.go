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

	starlarkjson "go.starlark.net/lib/json"
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

// fileOptions is the Starlark dialect of the module contract — SHARED by
// the validator (Validate) and the real runtime (Execute) so "validated
// today runs unchanged" holds exactly. Do not diverge these two callers.
func fileOptions() *syntax.FileOptions {
	return &syntax.FileOptions{
		// The contract deliberately allows the pragmatic conveniences the
		// agent's real runtime also enables: set() and reassignment.
		Set:               true,
		GlobalReassign:    true,
		TopLevelControl:   true,
		While:             true,
		Recursion:         false, // no recursion: bounds every module
		LoadBindsGlobally: false,
	}
}

// predeclared returns the extra globals injected into every module's
// environment beyond Starlark's own universe — IDENTICAL for validation and
// execution so "validate ≡ execute" still holds. Today it is a small set of
// safe Python-builtin shims that the Ansible→Starlark translations routinely
// emit but Starlark lacks — chiefly isinstance — so a lint-clean translation
// also runs instead of dying on an undefined name at module top level.
func predeclared() starlark.StringDict {
	return starlark.StringDict{
		"isinstance": starlark.NewBuiltin("isinstance", builtinIsInstance),
		// json.decode/encode/indent (go.starlark.net/lib/json): Checkmk checks
		// routinely parse JSON agent output, so a check translation that calls
		// json.decode must both lint-clean AND run. Shared by validation and
		// execution (predeclared is the single source), so "validate ≡ execute"
		// holds. Ansible action modules don't need it but it's harmless there.
		"json": starlarkjson.Module,
	}
}

// isinstanceTypeName maps a Starlark type-constructor builtin (str, int, …) to
// the Value.Type() string it constructs, so isinstance(x, str) can compare
// x.Type() to "string".
var isinstanceTypeName = map[string]string{
	"str": "string", "int": "int", "float": "float", "bool": "bool",
	"list": "list", "dict": "dict", "tuple": "tuple", "bytes": "bytes",
}

// builtinIsInstance implements Python's isinstance(x, classinfo) for the
// subset the translations use: classinfo is a type constructor (str/int/…) or
// a tuple of them. Anything else fails with a clear message rather than
// silently returning false.
func builtinIsInstance(_ *starlark.Thread, _ *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var x, classinfo starlark.Value
	if err := starlark.UnpackPositionalArgs("isinstance", args, kwargs, 2, &x, &classinfo); err != nil {
		return nil, err
	}
	match, err := isInstanceMatch(x, classinfo)
	if err != nil {
		return nil, err
	}
	return starlark.Bool(match), nil
}

func isInstanceMatch(x, classinfo starlark.Value) (bool, error) {
	switch c := classinfo.(type) {
	case *starlark.Builtin:
		want, ok := isinstanceTypeName[c.Name()]
		if !ok {
			return false, fmt.Errorf("isinstance: unsupported type %q", c.Name())
		}
		if x.Type() == want {
			return true, nil
		}
		// Python treats bool as a subclass of int.
		if want == "int" && x.Type() == "bool" {
			return true, nil
		}
		return false, nil
	case starlark.Tuple:
		for _, e := range c {
			m, err := isInstanceMatch(x, e)
			if err != nil {
				return false, err
			}
			if m {
				return true, nil
			}
		}
		return false, nil
	default:
		return false, fmt.Errorf("isinstance: second arg must be a type or tuple of types, got %s", classinfo.Type())
	}
}

// Validate runs the full pipeline: parse → contract lint → stub runs.
func Validate(filename string, src []byte, opts Options) Report {
	rep := Report{}

	fileOpts := fileOptions()

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

	globals, err := starlark.ExecFileOptions(fileOpts, thread, filename, src, predeclared())
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

// RunResult is what a ctx.run implementation returns to the runtime; it maps
// onto the Starlark `run_result` struct handed to the module.
type RunResult struct {
	RC      int
	Stdout  string
	Stderr  string
	Skipped bool
}

// Capabilities is the system-facing backend behind the ctx builtins. The
// validator (StubCtx) and the real runtime (RealCaps, internal/server) both
// implement it, so ctx has ONE construction path (buildCtx) and thus an
// identical shape — validate ≡ execute. The write gate / dry-run / timeout /
// ok_codes are enforced INSIDE the implementation, never by the module.
type Capabilities interface {
	CheckMode() bool
	// Run executes argv (no shell). mutates marks a state-changing command
	// (skipped in check_mode). An rc outside okCodes should be reported via a
	// returned error (fail()); a returned error aborts the module.
	Run(argv []string, mutates bool, okCodes []int) (RunResult, error)
	FileRead(path string) (string, error)
	// FileWrite returns whether the content changed; mode is an octal string
	// like "0644" or "" for none.
	FileWrite(path, content, mode string) (changed bool, err error)
	FileExists(path string) (bool, error)
	// Stat returns the stat attribute dict, or nil for a missing path.
	Stat(path string) (map[string]any, error)
	Facts() (map[string]any, error)
	// Probe performs a client-side network probe — the primitive behind
	// active service checks (kind "http" | "tcp" | "dns"). Read-only by
	// nature (a network CLIENT call), so it is not write-gated. params and
	// the result dict are kind-specific; a transport failure is reported
	// INSIDE the result (an "error" key), not as a Go error, so the check
	// grades it CRIT instead of aborting.
	Probe(kind string, params map[string]any) (map[string]any, error)
}

// buildCtx assembles the ctx struct from a Capabilities backend — the single
// place the ctx member set + signatures are defined, shared by StubCtx and
// the real runtime. rec may be nil (no recording).
func buildCtx(caps Capabilities, rec *Recorder) *starlarkstruct.Struct {
	members := starlark.StringDict{
		"check_mode": starlark.Bool(caps.CheckMode()),
		"run": starlark.NewBuiltin("run", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var argv *starlark.List
			var mutates bool
			var okCodes starlark.Value = starlark.None
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "argv", &argv, "mutates?", &mutates, "ok_codes?", &okCodes); err != nil {
				return nil, err
			}
			rec.record("run(%s, mutates=%v)", argv.String(), mutates)
			rr, err := caps.Run(argvStrings(argv), mutates, okCodesInts(okCodes))
			if err != nil {
				return nil, err
			}
			return starlarkstruct.FromStringDict(starlark.String("run_result"), starlark.StringDict{
				"rc":      starlark.MakeInt(rr.RC),
				"stdout":  starlark.String(rr.Stdout),
				"stderr":  starlark.String(rr.Stderr),
				"skipped": starlark.Bool(rr.Skipped),
			}), nil
		}),
		"file_read": starlark.NewBuiltin("file_read", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var path string
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path); err != nil {
				return nil, err
			}
			rec.record("file_read(%q)", path)
			s, err := caps.FileRead(path)
			if err != nil {
				return nil, err
			}
			return starlark.String(s), nil
		}),
		"file_write": starlark.NewBuiltin("file_write", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var path, content string
			var mode starlark.Value = starlark.None
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path, "content", &content, "mode?", &mode); err != nil {
				return nil, err
			}
			rec.record("file_write(%q, %d bytes, check_mode=%v)", path, len(content), caps.CheckMode())
			changed, err := caps.FileWrite(path, content, modeString(mode))
			if err != nil {
				return nil, err
			}
			return starlark.Bool(changed), nil
		}),
		"file_exists": starlark.NewBuiltin("file_exists", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var path string
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path); err != nil {
				return nil, err
			}
			rec.record("file_exists(%q)", path)
			ok, err := caps.FileExists(path)
			if err != nil {
				return nil, err
			}
			return starlark.Bool(ok), nil
		}),
		"stat": starlark.NewBuiltin("stat", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var path string
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "path", &path); err != nil {
				return nil, err
			}
			rec.record("stat(%q)", path)
			m, err := caps.Stat(path)
			if err != nil {
				return nil, err
			}
			if m == nil {
				return starlark.None, nil
			}
			return goToStarlark(m)
		}),
		"facts": starlark.NewBuiltin("facts", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			if err := starlark.UnpackArgs(b.Name(), args, kwargs); err != nil {
				return nil, err
			}
			rec.record("facts()")
			m, err := caps.Facts()
			if err != nil {
				return nil, err
			}
			return goToStarlark(m)
		}),
		// ctx.probe(kind, params) — client-side network probe for active
		// service checks: kind "http" (request + timing + TLS cert facts),
		// "tcp" (connect / optional send-expect banner), "dns" (resolve).
		// Returns a dict of raw facts; the check grades them OK/WARN/CRIT.
		"probe": starlark.NewBuiltin("probe", func(t *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
			var kind string
			var params starlark.Value = starlark.None
			if err := starlark.UnpackArgs(b.Name(), args, kwargs, "kind", &kind, "params?", &params); err != nil {
				return nil, err
			}
			rec.record("probe(%q)", kind)
			var pm map[string]any
			if params != starlark.None {
				goVal, err := starlarkToGo(params)
				if err != nil {
					return nil, err
				}
				m, ok := goVal.(map[string]any)
				if !ok {
					return nil, fmt.Errorf("probe: params must be a dict")
				}
				pm = m
			}
			res, err := caps.Probe(kind, pm)
			if err != nil {
				return nil, err
			}
			return goToStarlark(res)
		}),
	}
	return starlarkstruct.FromStringDict(starlark.String("ctx"), members)
}

// StubCtx builds the mocked ctx struct handed to main() during validation —
// buildCtx over a canned backend, so it has the exact same shape as the real
// runtime's ctx (only the implementations are inert).
func StubCtx(checkMode bool, rec *Recorder) *starlarkstruct.Struct {
	return buildCtx(stubCaps{checkMode: checkMode}, rec)
}

// stubCaps is the validator's inert backend: no I/O, canned returns matching
// the historical stub behavior (rc=0, empty output, "would change", no file,
// canned facts).
type stubCaps struct{ checkMode bool }

func (s stubCaps) CheckMode() bool { return s.checkMode }
func (s stubCaps) Run(_ []string, mutates bool, _ []int) (RunResult, error) {
	return RunResult{Skipped: s.checkMode && mutates}, nil
}
func (s stubCaps) FileRead(string) (string, error)                { return "", nil }
func (s stubCaps) FileWrite(string, string, string) (bool, error) { return true, nil }
func (s stubCaps) FileExists(string) (bool, error)                { return false, nil }
func (s stubCaps) Stat(string) (map[string]any, error)            { return nil, nil }
func (s stubCaps) Probe(kind string, _ map[string]any) (map[string]any, error) {
	// Inert validator backend: no network I/O. Shape mirrors the real
	// probes' common keys so a check's field access validates.
	return map[string]any{"kind": kind, "error": "", "stub": true,
		"status_code": 200, "response_ms": 1.0, "body": "", "connected": true,
		"connect_ms": 1.0, "received": "", "records": []any{}, "resolve_ms": 1.0,
		"cert_days_left": 365, "cert_subject": "stub"}, nil
}
func (s stubCaps) Facts() (map[string]any, error) {
	return map[string]any{
		"os_family":    "debian",
		"distribution": "debian",
		"hostname":     "stub-host",
		"architecture": "x86_64",
	}, nil
}

// Result is a module's validated return value, converted to Go.
type Result struct {
	Changed bool
	Msg     string
	Data    any
}

// Execute runs a module's main(ctx, params) for real against caps (Block G3).
// It mirrors stubRun's harness exactly (same fileOptions, step bound, Call),
// then enforces the return contract (checkResult) and converts the result to
// Go. The caller (a StarModule) supplies caps carrying the write gate +
// check_mode. Only parse+lint-valid modules should be Executed (the loader
// validates at load); Execute itself does not re-lint.
func Execute(filename string, src []byte, params map[string]any, caps Capabilities, opts Options) (Result, error) {
	maxSteps := opts.MaxSteps
	if maxSteps == 0 {
		maxSteps = defaultMaxSteps
	}
	thread := &starlark.Thread{Name: "execute:" + filename}
	thread.SetMaxExecutionSteps(maxSteps)

	p, err := goToStarlark(anyMap(params))
	if err != nil {
		return Result{}, fmt.Errorf("params: %w", err)
	}

	globals, err := starlark.ExecFileOptions(fileOptions(), thread, filename, src, predeclared())
	if err != nil {
		return Result{}, execError("module top-level failed", err)
	}
	mainFn, ok := globals["main"]
	if !ok {
		return Result{}, fmt.Errorf("main not exported")
	}
	res, err := starlark.Call(thread, mainFn, starlark.Tuple{buildCtx(caps, nil), p}, nil)
	if err != nil {
		return Result{}, execError("main() failed", err)
	}
	if diags := checkResult("execute", res); len(diags) > 0 {
		return Result{}, fmt.Errorf("%s", diags[0].Message)
	}

	d := res.(*starlark.Dict)
	out := Result{}
	if v, found, _ := d.Get(starlark.String("changed")); found {
		out.Changed = bool(v.(starlark.Bool))
	}
	if v, found, _ := d.Get(starlark.String("msg")); found {
		out.Msg = string(v.(starlark.String))
	}
	if v, found, _ := d.Get(starlark.String("data")); found {
		data, err := starlarkToGo(v)
		if err != nil {
			return Result{}, fmt.Errorf("converting result data: %w", err)
		}
		out.Data = data
	}
	return out, nil
}

func execError(prefix string, err error) error {
	if evalErr, ok := err.(*starlark.EvalError); ok {
		return fmt.Errorf("%s: %s", prefix, evalErr.Backtrace())
	}
	return fmt.Errorf("%s: %w", prefix, err)
}

// anyMap adapts a map[string]any to the `any` goToStarlark expects.
func anyMap(m map[string]any) any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

// argvStrings coerces a Starlark argv list to []string. Non-string elements
// are stringified rather than erroring, preserving the validator's tolerance
// (real modules always pass strings).
func argvStrings(list *starlark.List) []string {
	if list == nil {
		return nil
	}
	out := make([]string, 0, list.Len())
	for i := 0; i < list.Len(); i++ {
		e := list.Index(i)
		if s, ok := starlark.AsString(e); ok {
			out = append(out, s)
		} else {
			out = append(out, e.String())
		}
	}
	return out
}

// okCodesInts reads the ok_codes argument: None → [0]; a list → its integer
// elements (non-ints skipped). Never errors.
func okCodesInts(v starlark.Value) []int {
	if v == nil || v == starlark.None {
		return []int{0}
	}
	list, ok := v.(*starlark.List)
	if !ok {
		return []int{0}
	}
	out := make([]int, 0, list.Len())
	for i := 0; i < list.Len(); i++ {
		if n, ok := list.Index(i).(starlark.Int); ok {
			if v64, ok := n.Int64(); ok {
				out = append(out, int(v64))
			}
		}
	}
	if len(out) == 0 {
		return []int{0}
	}
	return out
}

// modeString reads the file_write mode argument (a string like "0644", or
// None → "").
func modeString(v starlark.Value) string {
	if s, ok := starlark.AsString(v); ok {
		return s
	}
	return ""
}

// starlarkToGo converts a Starlark value back to a plain Go value — the
// inverse of goToStarlark, for a module's returned result data.
func starlarkToGo(v starlark.Value) (any, error) {
	switch x := v.(type) {
	case nil, starlark.NoneType:
		return nil, nil
	case starlark.Bool:
		return bool(x), nil
	case starlark.String:
		return string(x), nil
	case starlark.Int:
		if i, ok := x.Int64(); ok {
			return i, nil
		}
		return x.String(), nil // bigger than int64: keep as decimal string
	case starlark.Float:
		return float64(x), nil
	case *starlark.List:
		out := make([]any, 0, x.Len())
		for i := 0; i < x.Len(); i++ {
			e, err := starlarkToGo(x.Index(i))
			if err != nil {
				return nil, err
			}
			out = append(out, e)
		}
		return out, nil
	case starlark.Tuple:
		out := make([]any, 0, x.Len())
		for i := 0; i < x.Len(); i++ {
			e, err := starlarkToGo(x.Index(i))
			if err != nil {
				return nil, err
			}
			out = append(out, e)
		}
		return out, nil
	case *starlark.Dict:
		out := make(map[string]any, x.Len())
		for _, item := range x.Items() {
			key, ok := starlark.AsString(item[0])
			if !ok {
				return nil, fmt.Errorf("dict key must be a string, got %s", item[0].Type())
			}
			val, err := starlarkToGo(item[1])
			if err != nil {
				return nil, err
			}
			out[key] = val
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unsupported starlark value type %s", v.Type())
	}
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
	// Native Go numerics — probe results (and any other Go-built map) carry
	// real ints, unlike the JSON-decoded facts path which only sees float64.
	case int:
		return starlark.MakeInt(x), nil
	case int64:
		return starlark.MakeInt64(x), nil
	case float32:
		return starlark.Float(float64(x)), nil
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
