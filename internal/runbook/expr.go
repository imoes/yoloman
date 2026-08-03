package runbook

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/nikolalohinski/gonja/v2"
	"github.com/nikolalohinski/gonja/v2/exec"
)

// The runbook surface is Ansible task syntax, so its templating is REAL Jinja2 — filters
// (`| default(...)`, `| to_json`, …), tests (`is defined`), expressions and conditionals — not a
// hand-rolled subset. We route every arg / when / loop through gonja, the same Jinja2 engine + Ansible
// filter set the config-template renderer uses (internal/modules), so what renders in a playbook renders
// here identically. That is the "100% Ansible-compatible" contract for the runbook layer.
//
// Native types: Ansible yields the NATIVE value (list/dict/int/bool) when a value is EXACTLY one
// `{{ expr }}`, and a string when the placeholder is embedded in surrounding text. gonja's public API
// only renders to strings, so for the whole-expression case we evaluate `{{ (expr) | to_json }}` and
// json-decode the result — an engine-faithful way to recover the native type (this is how e.g.
// `dns: "{{ net.dns }}"` arrives as a real list, not its string repr).

func init() { modules.RegisterAnsibleFilters() }

// wholeExprRe matches a string that is exactly one {{ … }} (possibly with surrounding whitespace).
var wholeExprRe = regexp.MustCompile(`(?s)^\s*\{\{(.+)\}\}\s*$`)

func renderTemplate(tmpl string, ctx map[string]any) (string, error) {
	t, err := gonja.FromString(tmpl)
	if err != nil {
		return "", fmt.Errorf("template parse %q: %w", tmpl, err)
	}
	out, err := t.ExecuteToString(exec.NewContext(ctx))
	if err != nil {
		return "", fmt.Errorf("template render %q: %w", tmpl, err)
	}
	return out, nil
}

// evalExpr evaluates one Jinja expression to a native Go value via a to_json round-trip.
func evalExpr(expr string, ctx map[string]any) (any, error) {
	js, err := renderTemplate("{{ ("+expr+") | to_json }}", ctx)
	if err != nil {
		return nil, err
	}
	js = strings.TrimSpace(js)
	var v any
	if err := json.Unmarshal([]byte(js), &v); err != nil {
		// to_json should always emit JSON; if not, fall back to the raw rendered text.
		return js, nil
	}
	return v, nil
}

// substitute walks val: a string that is exactly one {{ expr }} becomes the native-typed value; a
// string with embedded placeholders (or {% %}) is rendered to a string; containers recurse; other
// scalars pass through unchanged.
func substitute(val any, ctx map[string]any) (any, error) {
	switch v := val.(type) {
	case string:
		if m := wholeExprRe.FindStringSubmatch(v); m != nil {
			return evalExpr(strings.TrimSpace(m[1]), ctx)
		}
		if strings.Contains(v, "{{") || strings.Contains(v, "{%") {
			return renderTemplate(v, ctx)
		}
		return v, nil
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, e := range v {
			r, err := substitute(e, ctx)
			if err != nil {
				return nil, err
			}
			out[k] = r
		}
		return out, nil
	case []any:
		out := make([]any, len(v))
		for i, e := range v {
			r, err := substitute(e, ctx)
			if err != nil {
				return nil, err
			}
			out[i] = r
		}
		return out, nil
	default:
		return v, nil
	}
}

// evalWhen evaluates an Ansible `when:` — a bare Jinja expression — to a boolean.
func evalWhen(expr string, ctx map[string]any) (bool, error) {
	v, err := evalExpr(expr, ctx)
	if err != nil {
		return false, err
	}
	return truthy(v), nil
}

// resolveLoop evaluates a `loop:` value to a list: a literal list passes through; a string is a Jinja
// expression (a bare name or a {{ … }}) that must yield a list.
func resolveLoop(loop any, ctx map[string]any) ([]any, error) {
	if loop == nil {
		return []any{nil}, nil
	}
	switch l := loop.(type) {
	case []any:
		return l, nil
	case string:
		expr := strings.TrimSpace(l)
		if m := wholeExprRe.FindStringSubmatch(expr); m != nil {
			expr = strings.TrimSpace(m[1])
		}
		v, err := evalExpr(expr, ctx)
		if err != nil {
			return nil, err
		}
		lst, ok := v.([]any)
		if !ok {
			return nil, fmt.Errorf("loop %q did not resolve to a list", l)
		}
		return lst, nil
	default:
		return nil, fmt.Errorf("loop must be a list or an expression string")
	}
}

// truthy applies Ansible/Python truthiness to a rendered value.
func truthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case string:
		return x != "" && strings.ToLower(x) != "false"
	case float64:
		return x != 0
	case int:
		return x != 0
	case []any:
		return len(x) > 0
	case map[string]any:
		return len(x) > 0
	default:
		return true
	}
}
