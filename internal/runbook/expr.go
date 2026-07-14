package runbook

import (
	"fmt"
	"regexp"
	"strings"
)

// placeholderRe matches {{ dotted.path }} — a superset of the tasks package's
// simple {{ name }} (runbook vars include dotted registered results).
var placeholderRe = regexp.MustCompile(`\{\{\s*([a-zA-Z_][a-zA-Z0-9_.]*)\s*\}\}`)

// resolvePath walks a dotted path against the context. Returns (value, true)
// or (nil, false) if any segment is missing.
func resolvePath(path string, ctx map[string]any) (any, bool) {
	var cur any = ctx
	for _, part := range strings.Split(path, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		v, ok := m[part]
		if !ok {
			return nil, false
		}
		cur = v
	}
	return cur, true
}

// substitute walks val replacing every {{ path }} with the resolved value: a
// string that is *entirely* one placeholder becomes the native-typed value; an
// embedded placeholder is stringified. An unresolved reference is an error.
func substitute(val any, ctx map[string]any) (any, error) {
	switch v := val.(type) {
	case string:
		trimmed := strings.TrimSpace(v)
		if m := placeholderRe.FindStringSubmatch(trimmed); m != nil && m[0] == trimmed {
			rv, ok := resolvePath(m[1], ctx)
			if !ok {
				return nil, fmt.Errorf("unresolved parameter reference {{ %s }}", m[1])
			}
			return rv, nil
		}
		var subErr error
		out := placeholderRe.ReplaceAllStringFunc(v, func(match string) string {
			name := placeholderRe.FindStringSubmatch(match)[1]
			rv, ok := resolvePath(name, ctx)
			if !ok {
				subErr = fmt.Errorf("unresolved parameter reference {{ %s }}", name)
				return match
			}
			return fmt.Sprintf("%v", rv)
		})
		if subErr != nil {
			return nil, subErr
		}
		return out, nil
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, vv := range v {
			sv, err := substitute(vv, ctx)
			if err != nil {
				return nil, err
			}
			out[k] = sv
		}
		return out, nil
	case []any:
		out := make([]any, len(v))
		for i, vv := range v {
			sv, err := substitute(vv, ctx)
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

var (
	reIsNotDefined = regexp.MustCompile(`^([\w.]+)\s+is\s+not\s+defined$`)
	reIsDefined    = regexp.MustCompile(`^([\w.]+)\s+is\s+defined$`)
	reCmp          = regexp.MustCompile(`^([\w.]+)\s*(==|!=|>=|<=|>|<)\s*(.+)$`)
	reBarePath     = regexp.MustCompile(`^[\w.]+$`)
)

// evalWhen evaluates one when/assert condition against ctx, using the same
// deliberately-small grammar as Bossman's when_eval (not a Jinja/eval): `not`,
// `is defined`, `is not defined`, ==/!=/>/>=/</<=, and a bare truthy path.
func evalWhen(expr string, ctx map[string]any) (bool, error) {
	expr = strings.TrimSpace(expr)
	if strings.HasPrefix(expr, "not ") {
		v, err := evalWhen(expr[4:], ctx)
		return !v, err
	}
	if m := reIsNotDefined.FindStringSubmatch(expr); m != nil {
		_, ok := resolvePath(m[1], ctx)
		return !ok, nil
	}
	if m := reIsDefined.FindStringSubmatch(expr); m != nil {
		_, ok := resolvePath(m[1], ctx)
		return ok, nil
	}
	if m := reCmp.FindStringSubmatch(expr); m != nil {
		path, op, litText := m[1], m[2], m[3]
		lhs, ok := resolvePath(path, ctx)
		lit := parseLiteral(litText)
		switch op {
		case "==":
			return ok && equalish(lhs, lit), nil
		case "!=":
			return !ok || !equalish(lhs, lit), nil
		case ">", ">=", "<", "<=":
			ln, lok := numeric(lhs)
			rn, rok := numeric(lit)
			if !ok || !lok || !rok {
				return false, nil
			}
			switch op {
			case ">":
				return ln > rn, nil
			case ">=":
				return ln >= rn, nil
			case "<":
				return ln < rn, nil
			default:
				return ln <= rn, nil
			}
		}
	}
	if reBarePath.MatchString(expr) {
		v, ok := resolvePath(expr, ctx)
		if !ok {
			return false, nil
		}
		return truthy(v), nil
	}
	return false, fmt.Errorf("unsupported when-expression %q", expr)
}

func parseLiteral(text string) any {
	text = strings.TrimSpace(text)
	switch text {
	case "true":
		return true
	case "false":
		return false
	}
	if len(text) >= 2 && (text[0] == '\'' || text[0] == '"') && text[len(text)-1] == text[0] {
		return text[1 : len(text)-1]
	}
	if n, ok := numeric(text); ok {
		return n
	}
	return text
}

func equalish(a, b any) bool {
	if an, aok := numeric(a); aok {
		if bn, bok := numeric(b); bok {
			return an == bn
		}
	}
	return fmt.Sprintf("%v", a) == fmt.Sprintf("%v", b)
}

func truthy(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t != "" && t != "false"
	case nil:
		return false
	default:
		if n, ok := numeric(v); ok {
			return n != 0
		}
		return true
	}
}
