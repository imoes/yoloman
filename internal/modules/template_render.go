package modules

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/nikolalohinski/gonja/v2"
	"github.com/nikolalohinski/gonja/v2/exec"
)

// TemplateRender renders a full Jinja2 template (loops, conditionals, filters —
// via gonja, a Jinja2 engine) against a `values` context and writes it to `dest`. This is the
// Class-B config mechanism: free-form/complex files (nginx, apache, bind) that
// have no clean codec are OWNED as template + values — the state carries the
// values, this renders them to the on-disk file. Unlike the simpler `template`
// module (which only substitutes {{ name }}), this is a real Jinja2 engine, so
// a package's whole config can be expressed as one template.
//
// gonja is pure Go, so this keeps the agent a dependency-free static binary
// (no Python/Jinja2 on the host, and rendering works standalone).
type TemplateRender struct{}

// NewTemplateRender returns a TemplateRender module.
func NewTemplateRender() *TemplateRender { return &TemplateRender{} }

func (t *TemplateRender) Name() string { return "template_render" }

func (t *TemplateRender) Description() string {
	return "" +
		"Render a full Jinja2 template (loops, if/else, filters, tests like `is defined` — gonja) against a `values` " +
		"context and write it to `dest`. The Class-B config mechanism: own a complex config file " +
		"(nginx/apache/bind) as template + values. Idempotent — writes only when the rendered " +
		"output differs from dest; dry_run-aware. Params: `template` (the Jinja2 source), `dest`, " +
		"`values` (the render context). Distinct from `template`, which only does {{ name }} " +
		"substitution.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.template (Jinja2). Salt/Puppet: file.managed + jinja / .erb."
}

func (t *TemplateRender) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"template":      stringProp("The Jinja2 template source (inline). Prefer template_path in a runbook — inline {{ }} collides with the runbook's own substitution."),
		"template_path": stringProp("Path to a Jinja2 template file on the host (the runbook-safe way — its {{ }} is not touched by runbook substitution)."),
		"dest":          stringProp("Destination path to write the rendered file, e.g. /etc/nginx/nginx.conf."),
		"values":        map[string]any{"type": "object", "description": "The template render context (variables)."},
	}, "dest")
}

func (t *TemplateRender) Writes() bool { return true }

func (t *TemplateRender) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	tmplText, _ := params["template"].(string)
	dest, _ := params["dest"].(string)
	if dest == "" {
		return Result{}, fmt.Errorf("template_render: dest is required")
	}
	if tmplPath, _ := params["template_path"].(string); tmplPath != "" {
		b, err := os.ReadFile(tmplPath)
		if err != nil {
			return Result{}, fmt.Errorf("template_render: read template %s: %w", tmplPath, err)
		}
		tmplText = string(b)
	}
	if tmplText == "" {
		return Result{}, fmt.Errorf("template_render: template or template_path is required")
	}
	values, _ := params["values"].(map[string]any)
	if values == nil {
		values = map[string]any{}
	}

	// These templates are native Ansible; make gonja understand Ansible's filters (to_json, ternary,
	// dict2items, …) before parsing, or a template using one fails to render here even though Ansible
	// renders it fine. Idempotent, so calling it per render is free after the first.
	RegisterAnsibleFilters()

	tpl, err := gonja.FromString(tmplText)
	if err != nil {
		return Result{}, fmt.Errorf("template_render: parse: %w", err)
	}
	// JSON decodes every number to float64, which renders as "4.000000";
	// coerce integral floats back to ints so a config gets "workers 4".
	ctxValues, _ := normalizeNumbers(values).(map[string]any)
	rendered, err := tpl.ExecuteToString(exec.NewContext(ctxValues))
	if err != nil {
		return Result{}, fmt.Errorf("template_render: render: %w", err)
	}

	existing, readErr := os.ReadFile(dest)
	if readErr != nil && !os.IsNotExist(readErr) {
		return Result{}, fmt.Errorf("template_render: read %s: %w", dest, readErr)
	}
	changed := string(existing) != rendered
	if changed && !dryRun {
		// The destination directory may not exist yet (e.g. rendering a config
		// right after a fresh install, or for a package that ships none) —
		// create it rather than failing the render.
		if dir := filepath.Dir(dest); dir != "" && dir != "." {
			if merr := os.MkdirAll(dir, 0o755); merr != nil {
				return Result{}, fmt.Errorf("template_render: mkdir %s: %w", dir, merr)
			}
		}
		mode := os.FileMode(0o644)
		if fi, e := os.Stat(dest); e == nil {
			mode = fi.Mode().Perm()
		}
		if werr := os.WriteFile(dest, []byte(rendered), mode); werr != nil {
			return Result{}, fmt.Errorf("template_render: write %s: %w", dest, werr)
		}
	}
	msg := "unchanged"
	if changed {
		if dryRun {
			msg = "would render " + dest
		} else {
			msg = "rendered " + dest
		}
	}
	return Result{Changed: changed, Msg: msg, Data: map[string]any{"dest": dest, "rendered": rendered}}, nil
}

// normalizeNumbers recursively coerces integral float64 values (JSON's only
// number type) to int64, so templates render "4" not "4.000000".
func normalizeNumbers(v any) any {
	switch t := v.(type) {
	case float64:
		if t == float64(int64(t)) {
			return int64(t)
		}
		return t
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, vv := range t {
			out[k] = normalizeNumbers(vv)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, vv := range t {
			out[i] = normalizeNumbers(vv)
		}
		return out
	default:
		return v
	}
}
