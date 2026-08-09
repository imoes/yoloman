package modules

import (
	"context"
	"fmt"
	"os"
	"regexp"
)

// templatePlaceholderRe matches Jinja2-style {{ variable }} references —
// the subset of Jinja2 this module actually supports (see Template's
// Description).
var templatePlaceholderRe = regexp.MustCompile(`\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}`)

// Template renders {{ variable }} placeholders in template text against a
// vars map and writes the result to dest, mirroring the core idea of
// ansible.builtin.template. It is idempotent: it only writes when the
// rendered content differs from dest's current content.
//
// This intentionally implements a reduced subset of Jinja2 — plain
// {{ variable }} substitution only, no filters/conditionals/loops/macros —
// matching the same {{ }} placeholder convention already used by this
// project's own tools.d task definitions (see internal/tasks), so the
// mental model stays consistent across the whole agent rather than pulling
// in a full template-language dependency for one module.
type Template struct{}

// NewTemplate returns a Template module.
func NewTemplate() *Template { return &Template{} }

func (t *Template) Name() string { return "template" }

func (t *Template) Description() string {
	return "" +
		"Render {{ variable }} placeholders in template text against a `vars` map and write the " +
		"result to `dest` — the same {{ }} placeholder convention this agent's own tools.d task " +
		"definitions use, kept consistent rather than introducing a second templating syntax. " +
		"This is a deliberately reduced subset of Jinja2: plain variable substitution only — no " +
		"filters, conditionals, loops, or macros. Provide `content` (the template text inline) " +
		"or `src` (a path to an existing template file already on this host — there is no " +
		"separate control-node filesystem in this agent's single-host model, unlike a real " +
		"Ansible control node). Idempotent — compares the rendered output against dest's current " +
		"bytes and only writes when they differ. Supports check_mode via dry_run=true. Every " +
		"placeholder referenced in the template must have a corresponding entry in `vars`, or " +
		"the call fails with an error naming the missing variable — silently rendering a blank " +
		"would be worse than refusing.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.template. Ansible's template engine is full Jinja2 " +
		"(filters, conditionals, loops, macros); this module supports only {{ variable }} " +
		"substitution — treat it as covering the common case, not a full replacement for " +
		"complex Jinja2 templates.\n" +
		"- Chef: ERB templates via the `template` resource (`erb` — a different, more " +
		"powerful, Ruby-based syntax).\n" +
		"- Puppet: ERB or EPP templates via the `template()`/`epp()` functions inside a `file` " +
		"resource's `content`.\n" +
		"- Salt: Jinja2 templates via the `file.managed` state's `template: jinja` option — " +
		"much closer to Ansible's own templating than this module's reduced subset.\n" +
		"- Terraform: the `templatefile()` function or a `local_file`/`template_file` resource, " +
		"using Terraform's own `${}` interpolation syntax."
}

func (t *Template) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"dest":    stringProp(`Destination path to write the rendered content, e.g. "/etc/nginx/conf.d/app.conf".`),
		"content": stringProp("Literal template text, containing {{ variable }} placeholders. Mutually exclusive with src."),
		"src":     stringProp("Path to an existing template file on this host, containing {{ variable }} placeholders. Mutually exclusive with content."),
		"vars": map[string]any{
			"type":                 "object",
			"additionalProperties": map[string]any{"type": "string"},
			"description":          "Values to substitute for each {{ name }} placeholder found in the template.",
		},
		"owner":   stringProp("Optional desired owner (username or numeric uid)."),
		"group":   stringProp("Optional desired group (group name or numeric gid)."),
		"mode":    stringProp(`Optional desired permission mode as an octal string, e.g. "0644".`),
		"dry_run": boolProp("When true, report what would change without writing (check_mode).", false),
	}, "dest")
}

func (t *Template) Writes() bool { return true }

func (t *Template) Run(ctx context.Context, params map[string]any, dryRunArg bool) (Result, error) {
	dest, err := stringParam(params, "dest", true, "")
	if err != nil {
		return Result{}, err
	}
	content, err := stringParam(params, "content", false, "")
	if err != nil {
		return Result{}, err
	}
	src, err := stringParam(params, "src", false, "")
	if err != nil {
		return Result{}, err
	}
	owner, err := stringParam(params, "owner", false, "")
	if err != nil {
		return Result{}, err
	}
	group, err := stringParam(params, "group", false, "")
	if err != nil {
		return Result{}, err
	}
	mode, err := stringParam(params, "mode", false, "")
	if err != nil {
		return Result{}, err
	}
	paramDryRun, err := boolParam(params, "dry_run", false)
	if err != nil {
		return Result{}, err
	}
	dryRun := dryRunArg || paramDryRun

	vars, err := stringMapParam(params, "vars")
	if err != nil {
		return Result{}, err
	}

	_, hasContent := params["content"]
	_, hasSrc := params["src"]
	if hasContent == hasSrc {
		return Result{}, fmt.Errorf("template: exactly one of content or src must be given")
	}

	templateText := content
	if hasSrc {
		raw, err := os.ReadFile(src)
		if err != nil {
			return Result{}, fmt.Errorf("template: reading src %q: %w", src, err)
		}
		templateText = string(raw)
	}

	rendered, err := renderTemplate(templateText, vars)
	if err != nil {
		return Result{}, err
	}
	desired := []byte(rendered)

	current, readErr := os.ReadFile(dest)
	contentChanged := readErr != nil || string(current) != string(desired)

	if contentChanged && !dryRun {
		if err := os.WriteFile(dest, desired, 0o644); err != nil {
			return Result{}, fmt.Errorf("template: writing %q: %w", dest, err)
		}
	}

	changed := contentChanged
	if !dryRun || !contentChanged {
		if _, err := os.Lstat(dest); err == nil {
			attrChanged, err := applyOwnerGroupMode(dest, owner, group, mode, dryRun)
			if err != nil {
				return Result{}, err
			}
			changed = changed || attrChanged
		}
	}

	msg := "content already up to date"
	if changed {
		msg = "content or attributes updated"
	}
	return Result{Changed: changed, Msg: msg, Data: map[string]any{"dest": dest}}, nil
}

// renderTemplate substitutes every {{ name }} placeholder in text with
// vars[name], erroring on any placeholder with no corresponding entry.
func renderTemplate(text string, vars map[string]string) (string, error) {
	var missing string
	rendered := templatePlaceholderRe.ReplaceAllStringFunc(text, func(match string) string {
		name := templatePlaceholderRe.FindStringSubmatch(match)[1]
		v, ok := vars[name]
		if !ok {
			if missing == "" {
				missing = name
			}
			return match
		}
		return v
	})
	if missing != "" {
		return "", fmt.Errorf("template: no value given for placeholder {{ %s }}", missing)
	}
	return rendered, nil
}
