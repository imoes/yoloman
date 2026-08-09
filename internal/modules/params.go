package modules

import "fmt"

// stringParam extracts a string parameter from params. If missing and
// required, it returns an error; if missing and optional, it returns def.
func stringParam(params map[string]any, key string, required bool, def string) (string, error) {
	v, ok := params[key]
	if !ok || v == nil {
		if required {
			return "", fmt.Errorf("%s: missing required parameter", key)
		}
		return def, nil
	}
	s, ok := v.(string)
	if !ok {
		return "", fmt.Errorf("%s: expected string, got %T", key, v)
	}
	return s, nil
}

// boolParam extracts a bool parameter from params, defaulting to def when
// absent.
func boolParam(params map[string]any, key string, def bool) (bool, error) {
	v, ok := params[key]
	if !ok || v == nil {
		return def, nil
	}
	b, ok := v.(bool)
	if !ok {
		return false, fmt.Errorf("%s: expected bool, got %T", key, v)
	}
	return b, nil
}

// stringSliceParam extracts a []string parameter. It accepts both a native
// []string (as constructed directly in Go, e.g. in tests) and a []any of
// strings (as produced by decoding JSON, e.g. from an MCP tool call).
func stringSliceParam(params map[string]any, key string, required bool) ([]string, error) {
	v, ok := params[key]
	if !ok || v == nil {
		if required {
			return nil, fmt.Errorf("%s: missing required parameter", key)
		}
		return nil, nil
	}
	switch vv := v.(type) {
	case []string:
		return vv, nil
	case []any:
		out := make([]string, len(vv))
		for i, e := range vv {
			s, ok := e.(string)
			if !ok {
				return nil, fmt.Errorf("%s[%d]: expected string, got %T", key, i, e)
			}
			out[i] = s
		}
		return out, nil
	default:
		return nil, fmt.Errorf("%s: expected array of strings, got %T", key, v)
	}
}

// stringOrStringSliceParam extracts a parameter that accepts either a single
// string or an array of strings, always returning a []string — mirroring
// how Ansible modules commonly accept `name: foo` or `name: [foo, bar]`.
func stringOrStringSliceParam(params map[string]any, key string, required bool) ([]string, error) {
	if v, ok := params[key]; ok {
		if s, ok := v.(string); ok {
			return []string{s}, nil
		}
	}
	return stringSliceParam(params, key, required)
}
