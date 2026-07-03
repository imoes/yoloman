// Package tasks parses tools.d/*.yaml files — curated, named tool
// definitions written in Ansible-task syntax (an "ansible.builtin.<module>:"
// key with fixed/pre-supplied parameters, optionally with {{ placeholder }}
// values filled in by the caller) or as a predefined command pipeline — and
// resolves them against the module registry / pipeline executor at call
// time.
package tasks

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/mutkluge/agentic-mcp/internal/checks"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
)

// ParamSpec describes one parameter a task's caller may (or must) supply,
// substituted into the task's fixed body wherever "{{ name }}" appears.
type ParamSpec struct {
	Type     string `yaml:"type"`
	Required bool   `yaml:"required"`
	Pattern  string `yaml:"pattern"`
	Default  any    `yaml:"default"`
}

// Task is one parsed tools.d/*.yaml file.
type Task struct {
	Name        string
	Description string
	Params      map[string]ParamSpec

	// Exactly one of Module/Body (a module task), Pipeline (a pipeline
	// task), or Check (a Nagios/CheckMK-style plugin task) is set.
	Module   string
	Body     map[string]any
	Pipeline [][]string
	Check    []string
}

const ansiblePrefix = "ansible.builtin."

var placeholderRe = regexp.MustCompile(`\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}`)

// ParseFile parses one tools.d task file's YAML content.
func ParseFile(data []byte) (*Task, error) {
	var raw map[string]any
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("parsing task file: %w", err)
	}

	name, _ := raw["name"].(string)
	if name == "" {
		return nil, fmt.Errorf("task file: missing required 'name'")
	}
	description, _ := raw["description"].(string)

	params, err := parseParamSpecs(name, raw["params"])
	if err != nil {
		return nil, err
	}

	var moduleKey string
	var moduleBody map[string]any
	var pipelineRaw, checkRaw any
	for k, v := range raw {
		switch k {
		case "name", "description", "params":
			continue
		case "pipeline":
			pipelineRaw = v
			continue
		case "check":
			checkRaw = v
			continue
		}
		if !strings.HasPrefix(k, ansiblePrefix) {
			return nil, fmt.Errorf("task %q: unexpected top-level key %q (want name, description, params, pipeline, check, or a single ansible.builtin.<module> key)", name, k)
		}
		if moduleKey != "" {
			return nil, fmt.Errorf("task %q: multiple ansible.builtin.* keys found (%q and %q); exactly one module task is supported per file", name, moduleKey, k)
		}
		body, ok := v.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("task %q: %q value must be a mapping of module parameters", name, k)
		}
		moduleKey = k
		moduleBody = body
	}

	hasModule := moduleKey != ""
	hasPipeline := pipelineRaw != nil
	hasCheck := checkRaw != nil
	switch {
	case hasModule && !hasPipeline && !hasCheck:
		return &Task{
			Name:        name,
			Description: description,
			Params:      params,
			Module:      strings.TrimPrefix(moduleKey, ansiblePrefix),
			Body:        moduleBody,
		}, nil
	case hasPipeline && !hasModule && !hasCheck:
		stages, err := parsePipelineStages(name, pipelineRaw)
		if err != nil {
			return nil, err
		}
		return &Task{Name: name, Description: description, Params: params, Pipeline: stages}, nil
	case hasCheck && !hasModule && !hasPipeline:
		argv, err := parseCheckArgv(name, checkRaw)
		if err != nil {
			return nil, err
		}
		return &Task{Name: name, Description: description, Params: params, Check: argv}, nil
	default:
		return nil, fmt.Errorf("task %q: exactly one of an ansible.builtin.<module> key, a 'pipeline' key, or a 'check' key is required", name)
	}
}

func parseParamSpecs(taskName string, raw any) (map[string]ParamSpec, error) {
	specs := map[string]ParamSpec{}
	if raw == nil {
		return specs, nil
	}
	rawMap, ok := raw.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("task %q: 'params' must be a mapping", taskName)
	}
	for pname, rawSpec := range rawMap {
		specMap, ok := rawSpec.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("task %q: params.%s must be a mapping", taskName, pname)
		}
		spec := ParamSpec{Type: "string"}
		if t, ok := specMap["type"].(string); ok {
			spec.Type = t
		}
		if r, ok := specMap["required"].(bool); ok {
			spec.Required = r
		}
		if p, ok := specMap["pattern"].(string); ok {
			spec.Pattern = p
		}
		if d, ok := specMap["default"]; ok {
			spec.Default = d
		}
		if spec.Pattern != "" {
			if _, err := regexp.Compile(spec.Pattern); err != nil {
				return nil, fmt.Errorf("task %q: params.%s: invalid pattern %q: %w", taskName, pname, spec.Pattern, err)
			}
		}
		switch spec.Type {
		case "string", "bool", "number":
		default:
			return nil, fmt.Errorf("task %q: params.%s: unsupported type %q (want string|bool|number)", taskName, pname, spec.Type)
		}
		specs[pname] = spec
	}
	return specs, nil
}

func parsePipelineStages(taskName string, raw any) ([][]string, error) {
	stagesRaw, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("task %q: 'pipeline' must be a list of argv stages", taskName)
	}
	stages := make([][]string, 0, len(stagesRaw))
	for i, stageRaw := range stagesRaw {
		argvRaw, ok := stageRaw.([]any)
		if !ok {
			return nil, fmt.Errorf("task %q: pipeline stage %d must be a list of strings", taskName, i)
		}
		argv := make([]string, len(argvRaw))
		for j, a := range argvRaw {
			s, ok := a.(string)
			if !ok {
				return nil, fmt.Errorf("task %q: pipeline stage %d, arg %d: expected string, got %T", taskName, i, j, a)
			}
			argv[j] = s
		}
		if len(argv) == 0 {
			return nil, fmt.Errorf("task %q: pipeline stage %d must not be empty", taskName, i)
		}
		stages = append(stages, argv)
	}
	if len(stages) == 0 {
		return nil, fmt.Errorf("task %q: pipeline must have at least one stage", taskName)
	}
	return stages, nil
}

// parseCheckArgv parses a 'check:' value — a flat list of strings forming
// the Nagios/CheckMK-style plugin's argv (e.g. [check_disk, -w, "10%"]).
func parseCheckArgv(taskName string, raw any) ([]string, error) {
	argvRaw, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("task %q: 'check' must be a list of strings (the plugin argv)", taskName)
	}
	argv := make([]string, len(argvRaw))
	for i, a := range argvRaw {
		s, ok := a.(string)
		if !ok {
			return nil, fmt.Errorf("task %q: check[%d]: expected string, got %T", taskName, i, a)
		}
		argv[i] = s
	}
	if len(argv) == 0 {
		return nil, fmt.Errorf("task %q: 'check' must not be empty", taskName)
	}
	return argv, nil
}

// LoadDir parses every *.yaml/*.yml file directly under dir into a Task,
// erroring on duplicate task names. A missing dir is not an error — it
// simply yields no tasks (tools.d/ is optional).
func LoadDir(dir string) ([]*Task, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading tools.d %q: %w", dir, err)
	}

	var names []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if ext := filepath.Ext(e.Name()); ext == ".yaml" || ext == ".yml" {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	seen := map[string]string{}
	var tasksList []*Task
	for _, name := range names {
		path := filepath.Join(dir, name)
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("reading %q: %w", path, err)
		}
		task, err := ParseFile(data)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if prevFile, ok := seen[task.Name]; ok {
			return nil, fmt.Errorf("%s: duplicate task name %q (already defined in %s)", path, task.Name, prevFile)
		}
		seen[task.Name] = path
		tasksList = append(tasksList, task)
	}
	return tasksList, nil
}

// IsPipeline reports whether t is a pipeline task (as opposed to a module task).
func (t *Task) IsPipeline() bool { return t.Pipeline != nil }

// IsCheck reports whether t is a Nagios/CheckMK-style plugin check task.
func (t *Task) IsCheck() bool { return t.Check != nil }

// Writes reports whether running this task can mutate system state: for a
// module task, that's the underlying module's Writes(); a pipeline task is
// always treated as writing, since arbitrary chained commands cannot be
// assumed read-only; a check task is always read-only (a monitoring plugin
// inspects and reports, it does not change state), so it is always
// registered regardless of the write gate.
func (t *Task) Writes(reg *modules.Registry) (bool, error) {
	if t.IsPipeline() {
		return true, nil
	}
	if t.IsCheck() {
		return false, nil
	}
	m, ok := reg.Get(t.Module)
	if !ok {
		return false, fmt.Errorf("task %q references unknown module %q", t.Name, t.Module)
	}
	return m.Writes(), nil
}

// InputSchema returns a JSON Schema object built from Params, for MCP/REST
// tool registration.
func (t *Task) InputSchema() map[string]any {
	props := map[string]any{}
	var required []string
	for name, spec := range t.Params {
		prop := map[string]any{"type": jsonSchemaType(spec.Type)}
		if spec.Pattern != "" {
			prop["pattern"] = spec.Pattern
		}
		if spec.Default != nil {
			prop["default"] = spec.Default
		}
		props[name] = prop
		if spec.Required {
			required = append(required, name)
		}
	}
	schema := map[string]any{"type": "object", "properties": props}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

func jsonSchemaType(t string) string {
	switch t {
	case "bool":
		return "boolean"
	case "number":
		return "number"
	default:
		return "string"
	}
}

// buildArgs validates given against t.Params (required/type/pattern),
// applying defaults for missing optional params, and rejects unknown keys.
func (t *Task) buildArgs(given map[string]any) (map[string]any, error) {
	args := map[string]any{}
	for name, spec := range t.Params {
		v, ok := given[name]
		if !ok {
			if spec.Required {
				return nil, fmt.Errorf("%s: missing required parameter", name)
			}
			if spec.Default != nil {
				args[name] = spec.Default
			}
			continue
		}
		switch spec.Type {
		case "", "string":
			s, ok := v.(string)
			if !ok {
				return nil, fmt.Errorf("%s: expected string, got %T", name, v)
			}
			if spec.Pattern != "" {
				re := regexp.MustCompile(spec.Pattern) // validated at parse time
				if !re.MatchString(s) {
					return nil, fmt.Errorf("%s: value %q does not match required pattern %q", name, s, spec.Pattern)
				}
			}
			args[name] = s
		case "bool":
			b, ok := v.(bool)
			if !ok {
				return nil, fmt.Errorf("%s: expected bool, got %T", name, v)
			}
			args[name] = b
		case "number":
			switch v.(type) {
			case float64, int, int64:
				args[name] = v
			default:
				return nil, fmt.Errorf("%s: expected number, got %T", name, v)
			}
		}
	}
	for k := range given {
		if _, ok := t.Params[k]; !ok {
			return nil, fmt.Errorf("unknown parameter %q", k)
		}
	}
	return args, nil
}

// substitute walks val (a task Body value: string, map, or slice) replacing
// every "{{ name }}" reference with args[name]. A string value that is
// *entirely* one placeholder is replaced with the argument's native type
// (e.g. a bool stays a bool); a placeholder embedded in a larger string is
// stringified. Every referenced name must exist in args — an unresolved
// reference is an error, not a silent no-op.
func substitute(val any, args map[string]any) (any, error) {
	switch v := val.(type) {
	case string:
		trimmed := strings.TrimSpace(v)
		if m := placeholderRe.FindStringSubmatch(trimmed); m != nil && m[0] == trimmed {
			argVal, ok := args[m[1]]
			if !ok {
				return nil, fmt.Errorf("unresolved parameter reference {{ %s }}", m[1])
			}
			return argVal, nil
		}
		var subErr error
		replaced := placeholderRe.ReplaceAllStringFunc(v, func(m string) string {
			name := placeholderRe.FindStringSubmatch(m)[1]
			argVal, ok := args[name]
			if !ok {
				subErr = fmt.Errorf("unresolved parameter reference {{ %s }}", name)
				return m
			}
			return fmt.Sprintf("%v", argVal)
		})
		if subErr != nil {
			return nil, subErr
		}
		return replaced, nil
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, vv := range v {
			sv, err := substitute(vv, args)
			if err != nil {
				return nil, err
			}
			out[k] = sv
		}
		return out, nil
	case []any:
		out := make([]any, len(v))
		for i, vv := range v {
			sv, err := substitute(vv, args)
			if err != nil {
				return nil, err
			}
			out[i] = sv
		}
		return out, nil
	default:
		return val, nil
	}
}

// Run resolves t's parameters against given, substitutes them into the
// task body, and executes it: dispatching to the referenced module via reg
// for a module task, or to the pipeline executor for a pipeline task.
func (t *Task) Run(ctx context.Context, reg *modules.Registry, policy *pipeline.Policy, given map[string]any, dryRun bool) (modules.Result, error) {
	args, err := t.buildArgs(given)
	if err != nil {
		return modules.Result{}, err
	}

	if t.IsPipeline() {
		stages, err := substituteStages(t.Pipeline, args)
		if err != nil {
			return modules.Result{}, err
		}
		res, err := pipeline.Run(ctx, policy, stages, 0, 0)
		if err != nil {
			return modules.Result{}, err
		}
		return modules.Result{Changed: !dryRun, Msg: "pipeline executed", Data: res}, nil
	}

	if t.IsCheck() {
		argv, err := substituteArgv(t.Check, args)
		if err != nil {
			return modules.Result{}, err
		}
		res, err := checks.RunDefault(ctx, argv, 0)
		if err != nil {
			return modules.Result{}, err
		}
		return modules.Result{Changed: false, Msg: string(res.Status), Data: res}, nil
	}

	m, ok := reg.Get(t.Module)
	if !ok {
		return modules.Result{}, fmt.Errorf("task %q references unknown module %q", t.Name, t.Module)
	}
	resolved, err := substitute(t.Body, args)
	if err != nil {
		return modules.Result{}, err
	}
	body, ok := resolved.(map[string]any)
	if !ok {
		return modules.Result{}, fmt.Errorf("task %q: internal error: resolved body is not a map", t.Name)
	}
	return m.Run(ctx, body, dryRun)
}

// substituteArgv resolves {{ placeholder }} references in a flat argv
// (used for check tasks), stringifying each resolved value.
func substituteArgv(argv []string, args map[string]any) ([]string, error) {
	out := make([]string, len(argv))
	for i, s := range argv {
		v, err := substitute(s, args)
		if err != nil {
			return nil, err
		}
		out[i] = fmt.Sprintf("%v", v)
	}
	return out, nil
}

func substituteStages(stages [][]string, args map[string]any) ([][]string, error) {
	out := make([][]string, len(stages))
	for i, stage := range stages {
		resolvedStage := make([]string, len(stage))
		for j, s := range stage {
			v, err := substitute(s, args)
			if err != nil {
				return nil, err
			}
			resolvedStage[j] = fmt.Sprintf("%v", v)
		}
		out[i] = resolvedStage
	}
	return out, nil
}
