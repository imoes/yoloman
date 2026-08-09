package starmodules

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// ScriptModule runs an external script in ANY language via the Ansible/AWX
// stdin/stdout contract, so module functionality is language-agnostic (like
// Ansible, whose logic crosses the wire as stdin/stdout) with Python and Bash
// as first-class choices — no interpreter embedded in the Go agent.
//
//	stdin  : {"params": {...}, "dry_run": <bool>}
//	stdout : {"changed": <bool>, "msg": "...", "data": <any>, "failed": <bool>}
//
// A script that is not stdin/JSON-aware still works: non-JSON stdout is wrapped
// as msg and a non-zero exit becomes a failure. Dispatches through the same
// name-keyed modules.Registry as native Go and Starlark modules, so REST/MCP/CLI
// treat it identically; the write gate is honoured via Writes() plus an in-Run
// re-check (defense-in-depth).
type ScriptModule struct {
	fqcn        string
	shortName   string
	description string
	writes      bool
	agentWrite  bool
	options     map[string]any
	interpreter string // "python3" | "bash" | "/bin/sh" | "" (exec via shebang)
	src         []byte // the script source
	ext         string // ".py" | ".sh" … (temp-file suffix; drives shebang exec)
	timeout     time.Duration
}

var _ modules.Module = (*ScriptModule)(nil)

func (m *ScriptModule) Name() string        { return m.fqcn }
func (m *ScriptModule) Description() string { return m.description }
func (m *ScriptModule) Writes() bool        { return m.writes }

// InputSchema renders the sidecar argspec as JSON Schema, like StarModule.
func (m *ScriptModule) InputSchema() map[string]any {
	props := map[string]any{}
	var required []string
	for name, raw := range m.options {
		spec, _ := raw.(map[string]any)
		p := map[string]any{"type": jsonType(spec["type"])}
		if d, ok := spec["description"]; ok {
			p["description"] = d
		}
		if choices, ok := spec["choices"]; ok {
			p["enum"] = choices
		}
		props[name] = p
		if coerceBool(spec["required"]) {
			required = append(required, name)
		}
	}
	schema := map[string]any{"type": "object", "properties": props}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

// scriptResult is the JSON contract a script writes to stdout.
type scriptResult struct {
	Changed bool   `json:"changed"`
	Msg     string `json:"msg"`
	Data    any    `json:"data"`
	Failed  bool   `json:"failed"`
}

// Run feeds params+dry_run as JSON on stdin and parses the script's stdout as
// the result contract. dryRun (or params["dry_run"]) is passed through so the
// script can honour check_mode; a mutating script is refused when the agent
// write gate is closed (unless it's a dry run).
func (m *ScriptModule) Run(ctx context.Context, params map[string]any, dryRun bool) (modules.Result, error) {
	for name, raw := range m.options {
		spec, _ := raw.(map[string]any)
		if coerceBool(spec["required"]) {
			if _, ok := params[name]; !ok {
				return modules.Result{}, fmt.Errorf("%s: missing required parameter %q", m.fqcn, name)
			}
		}
	}
	checkMode := dryRun || coerceBool(params["dry_run"])
	if m.writes && !m.agentWrite && !checkMode {
		return modules.Result{}, fmt.Errorf("%s: refused — agent write gate is closed", m.fqcn)
	}

	inBytes, err := json.Marshal(map[string]any{"params": params, "dry_run": checkMode})
	if err != nil {
		return modules.Result{}, fmt.Errorf("%s: marshaling stdin: %w", m.fqcn, err)
	}

	// Materialize the script so the interpreter (or its shebang) can run it.
	tmp, err := os.CreateTemp("", "bossman-script-*"+m.ext)
	if err != nil {
		return modules.Result{}, fmt.Errorf("%s: %w", m.fqcn, err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(m.src); err != nil {
		tmp.Close()
		return modules.Result{}, fmt.Errorf("%s: %w", m.fqcn, err)
	}
	tmp.Close()
	_ = os.Chmod(tmp.Name(), 0o700)

	timeout := m.timeout
	if timeout <= 0 {
		timeout = 60 * time.Second
	}
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	argv := []string{tmp.Name()}
	if m.interpreter != "" {
		argv = []string{m.interpreter, tmp.Name()}
	}
	cmd := exec.CommandContext(cctx, argv[0], argv[1:]...)
	cmd.Stdin = bytes.NewReader(inBytes)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	exitCode := 0
	if runErr := cmd.Run(); runErr != nil {
		var ee *exec.ExitError
		if errors.As(runErr, &ee) {
			exitCode = ee.ExitCode()
		} else {
			return modules.Result{}, fmt.Errorf("%s: %w", m.fqcn, runErr) // couldn't start / timeout
		}
	}

	out := strings.TrimSpace(stdout.String())
	var parsed scriptResult
	if out != "" && json.Unmarshal([]byte(out), &parsed) == nil {
		res := modules.Result{Changed: parsed.Changed, Msg: parsed.Msg, Data: parsed.Data}
		if parsed.Failed || exitCode != 0 {
			if res.Msg == "" {
				res.Msg = strings.TrimSpace(stderr.String())
			}
			return res, fmt.Errorf("%s: script failed (exit %d): %s", m.fqcn, exitCode, res.Msg)
		}
		return res, nil
	}

	// Non-JSON stdout: best-effort mapping (a plain script still works).
	if exitCode != 0 {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = out
		}
		return modules.Result{Msg: msg}, fmt.Errorf("%s: script exit %d: %s", m.fqcn, exitCode, msg)
	}
	return modules.Result{Changed: false, Msg: out}, nil
}

// interpreterForExt maps a script extension to its default interpreter; an
// unknown extension returns "" → the file is exec'd directly (shebang + chmod).
func interpreterForExt(ext string) string {
	switch strings.ToLower(ext) {
	case ".py":
		return "python3"
	case ".sh", ".bash":
		return "bash"
	default:
		return ""
	}
}

// BuildScriptModule builds one ScriptModule from its script source + metadata
// sidecar (the same .nt/.yaml sidecar shape StarModule uses), the one
// construction path for the disk loader and any future delivery endpoint.
func BuildScriptModule(src, sidecar []byte, sidecarFormat, ext string, agentWrite bool) (*ScriptModule, error) {
	meta, err := parseSidecar(sidecar, sidecarFormat)
	if err != nil {
		return nil, err
	}
	fqcn, _ := meta["fqcn"].(string)
	name, _ := meta["name"].(string)
	if fqcn == "" || name == "" {
		return nil, fmt.Errorf("sidecar missing required 'fqcn'/'name'")
	}
	options, _ := meta["options"].(map[string]any)
	desc, _ := meta["short_description"].(string)
	if desc == "" {
		desc = fqcn
	}
	interp, _ := meta["interpreter"].(string)
	if interp == "" {
		interp = interpreterForExt(ext)
	}
	return &ScriptModule{
		fqcn:        fqcn,
		shortName:   name,
		description: desc,
		writes:      coerceBool(meta["writes"]),
		agentWrite:  agentWrite,
		options:     options,
		interpreter: interp,
		src:         src,
		ext:         ext,
	}, nil
}

// LoadScriptDir loads every <collection>/<name>.{py,sh,bash} script module
// (with its .nt/.yaml sidecar) under dir — the language-agnostic counterpart to
// LoadDir. A missing directory yields nothing; per-module failures are warnings,
// never fatal.
func LoadScriptDir(dir string, agentWrite bool) (mods []modules.Module, warnings []string, err error) {
	info, statErr := os.Stat(dir)
	if statErr != nil || !info.IsDir() {
		return nil, nil, nil
	}
	var paths []string
	walkErr := filepath.WalkDir(dir, func(path string, d os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if !d.IsDir() {
			switch strings.ToLower(filepath.Ext(path)) {
			case ".py", ".sh", ".bash":
				paths = append(paths, path)
			}
		}
		return nil
	})
	if walkErr != nil {
		return nil, nil, fmt.Errorf("scanning %q: %w", dir, walkErr)
	}
	sort.Strings(paths)
	for _, p := range paths {
		src, readErr := os.ReadFile(p)
		if readErr != nil {
			warnings = append(warnings, fmt.Sprintf("%s: %v", p, readErr))
			continue
		}
		sidecar, format, sErr := readSidecar(p)
		if sErr != nil {
			warnings = append(warnings, fmt.Sprintf("%s: %v", p, sErr))
			continue
		}
		m, bErr := BuildScriptModule(src, sidecar, format, filepath.Ext(p), agentWrite)
		if bErr != nil {
			warnings = append(warnings, bErr.Error())
			continue
		}
		mods = append(mods, m)
	}
	return mods, warnings, nil
}
