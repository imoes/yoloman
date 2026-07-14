package modules

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config is the Class-A structured-config codec: it maps a whole config file
// under /etc to/from JSON, both ways. Two modes on one module:
//
//   - READ (no `values`): parse the file at `path` into structured data and
//     return it — the "observed" side of the server-as-a-document model.
//   - WRITE (`values` given): serialize/merge those values back into the file,
//     preserving comments and untouched lines (keyvalue) or deep-merging
//     (json/yaml), and write only if the result differs.
//
// Because a codec round-trips (parse → edit → serialize), a config file becomes
// a first-class JSON resource: GET reads it into state, PUT writes it back,
// drift is just a diff. Free-form formats (nginx, apache) that have no clean
// codec are handled by the template+values path instead (Class B).
type Config struct{}

// NewConfig returns a Config module.
func NewConfig() *Config { return &Config{} }

func (c *Config) Name() string { return "config" }

func (c *Config) Description() string {
	return "" +
		"Read or write a structured config file as JSON (Class-A codec). `path` + `format` " +
		"(keyvalue | json | yaml). With no `values`: parses the file and returns its structured " +
		"data (read-only). With `values`: merges them into the file (manage=merge, default) or " +
		"makes the file contain exactly them (manage=exact), preserving comments/order for " +
		"keyvalue and deep-merging json/yaml; writes only on change (idempotent, dry_run-aware). " +
		"keyvalue tuning: `separator` (default \" \", e.g. \"=\") and `comment` (default \"#\"). " +
		"This is how a config file round-trips into the server-as-a-document model.\n\n" +
		"Cross-tool equivalents:\n" +
		"- Ansible: ansible.builtin.ini_file / lineinfile / template, or community.general codecs.\n" +
		"- Augeas: the same file↔tree idea (this ships the codecs in-process, no C dependency).\n" +
		"- Salt/Puppet: file.serialize / augeas providers."
}

func (c *Config) InputSchema() map[string]any {
	return objectSchema(map[string]any{
		"path":      stringProp("Config file path, e.g. /etc/ssh/sshd_config."),
		"format":    stringEnumProp("Config codec.", "keyvalue", "json", "yaml"),
		"values":    map[string]any{"type": "object", "description": "Desired values. Omit to read (parse) only."},
		"manage":    stringEnumProp("merge = set the given keys, keep the rest (default); exact = file holds exactly `values`.", "merge", "exact"),
		"separator": stringProp("keyvalue key/value separator (default \" \"; use \"=\" for key=value files)."),
		"comment":   stringProp("keyvalue comment marker (default \"#\")."),
	}, "path", "format")
}

func (c *Config) Writes() bool { return true }

func (c *Config) Run(ctx context.Context, params map[string]any, dryRun bool) (Result, error) {
	path, _ := params["path"].(string)
	format, _ := params["format"].(string)
	if path == "" || format == "" {
		return Result{}, fmt.Errorf("config: path and format are required")
	}
	codec, err := newCodec(format, params)
	if err != nil {
		return Result{}, err
	}

	existing, readErr := os.ReadFile(path)
	if readErr != nil && !os.IsNotExist(readErr) {
		return Result{}, fmt.Errorf("config: read %s: %w", path, readErr)
	}

	// READ mode: no values → parse and return the structured data.
	valuesRaw, hasValues := params["values"]
	if !hasValues {
		parsed, perr := codec.parse(existing)
		if perr != nil {
			return Result{}, fmt.Errorf("config: parse %s: %w", path, perr)
		}
		return Result{Changed: false, Msg: "read " + path, Data: map[string]any{"path": path, "format": format, "config": parsed}}, nil
	}

	values, ok := valuesRaw.(map[string]any)
	if !ok {
		return Result{}, fmt.Errorf("config: values must be an object")
	}
	manage, _ := params["manage"].(string)
	if manage == "" {
		manage = "merge"
	}

	rendered, rerr := codec.render(existing, values, manage)
	if rerr != nil {
		return Result{}, fmt.Errorf("config: render %s: %w", path, rerr)
	}
	changed := string(rendered) != string(existing)
	if changed && !dryRun {
		mode := os.FileMode(0o644)
		if fi, e := os.Stat(path); e == nil {
			mode = fi.Mode().Perm()
		}
		if werr := os.WriteFile(path, rendered, mode); werr != nil {
			return Result{}, fmt.Errorf("config: write %s: %w", path, werr)
		}
	}
	after, _ := codec.parse(rendered)
	msg := "unchanged"
	if changed {
		if dryRun {
			msg = "would update " + path
		} else {
			msg = "updated " + path
		}
	}
	return Result{Changed: changed, Msg: msg, Data: map[string]any{"path": path, "format": format, "config": after}}, nil
}

// ---- codecs ----

type configCodec interface {
	parse(data []byte) (map[string]any, error)
	render(existing []byte, values map[string]any, manage string) ([]byte, error)
}

func newCodec(format string, params map[string]any) (configCodec, error) {
	switch format {
	case "keyvalue":
		sep, _ := params["separator"].(string)
		if sep == "" {
			sep = " "
		}
		com, _ := params["comment"].(string)
		if com == "" {
			com = "#"
		}
		return &keyValueCodec{sep: sep, comment: com}, nil
	case "json":
		return &jsonCodec{}, nil
	case "yaml":
		return &yamlCodec{}, nil
	default:
		return nil, fmt.Errorf("config: unsupported format %q (want keyvalue|json|yaml)", format)
	}
}

// keyValueCodec handles line-oriented "KEY<sep>VALUE" files (sshd_config-style
// with sep=" ", or key=value with sep="="). It is structure-preserving: a
// merge updates existing keys in place and appends new ones, leaving comments,
// blank lines, and key order untouched.
type keyValueCodec struct {
	sep     string
	comment string
}

func (k *keyValueCodec) splitLine(line string) (key, val string, ok bool) {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || strings.HasPrefix(trimmed, k.comment) {
		return "", "", false
	}
	var idx int
	if k.sep == " " {
		idx = strings.IndexAny(trimmed, " \t")
	} else {
		idx = strings.Index(trimmed, k.sep)
	}
	if idx < 0 {
		return trimmed, "", true // bare directive, no value
	}
	return strings.TrimSpace(trimmed[:idx]), strings.TrimSpace(trimmed[idx+len(k.sep):]), true
}

func (k *keyValueCodec) parse(data []byte) (map[string]any, error) {
	out := map[string]any{}
	for _, line := range strings.Split(string(data), "\n") {
		if key, val, ok := k.splitLine(line); ok {
			out[key] = val
		}
	}
	return out, nil
}

func (k *keyValueCodec) format(key string, v any) string {
	return key + k.sep + fmt.Sprintf("%v", v)
}

func (k *keyValueCodec) render(existing []byte, values map[string]any, manage string) ([]byte, error) {
	want := map[string]string{}
	for key, v := range values {
		want[key] = fmt.Sprintf("%v", v)
	}

	if manage == "exact" {
		keys := make([]string, 0, len(want))
		for key := range want {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		var b strings.Builder
		for _, key := range keys {
			b.WriteString(k.format(key, want[key]))
			b.WriteByte('\n')
		}
		return []byte(b.String()), nil
	}

	// merge: rewrite matching lines in place, append the rest.
	seen := map[string]bool{}
	lines := strings.Split(string(existing), "\n")
	// A trailing empty element from a final newline: drop it, restore later.
	trailingNL := len(lines) > 0 && lines[len(lines)-1] == ""
	if trailingNL {
		lines = lines[:len(lines)-1]
	}
	for i, line := range lines {
		key, _, ok := k.splitLine(line)
		if !ok {
			continue
		}
		if nv, present := want[key]; present && !seen[key] {
			lines[i] = k.format(key, nv)
			seen[key] = true
		}
	}
	appended := make([]string, 0)
	appendKeys := make([]string, 0)
	for key := range want {
		if !seen[key] {
			appendKeys = append(appendKeys, key)
		}
	}
	sort.Strings(appendKeys)
	for _, key := range appendKeys {
		appended = append(appended, k.format(key, want[key]))
	}
	lines = append(lines, appended...)
	out := strings.Join(lines, "\n")
	if len(out) > 0 {
		out += "\n"
	}
	return []byte(out), nil
}

type jsonCodec struct{}

func (j *jsonCodec) parse(data []byte) (map[string]any, error) {
	if len(strings.TrimSpace(string(data))) == 0 {
		return map[string]any{}, nil
	}
	var m map[string]any
	if err := yaml.Unmarshal(data, &m); err != nil { // YAML is a JSON superset — parses both
		return nil, err
	}
	if m == nil {
		m = map[string]any{}
	}
	return m, nil
}

func (j *jsonCodec) render(existing []byte, values map[string]any, manage string) ([]byte, error) {
	result := values
	if manage != "exact" {
		cur, _ := j.parse(existing)
		result = deepMerge(cur, values)
	}
	out, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(out, '\n'), nil
}

type yamlCodec struct{}

func (y *yamlCodec) parse(data []byte) (map[string]any, error) {
	if len(strings.TrimSpace(string(data))) == 0 {
		return map[string]any{}, nil
	}
	var m map[string]any
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	if m == nil {
		m = map[string]any{}
	}
	return m, nil
}

func (y *yamlCodec) render(existing []byte, values map[string]any, manage string) ([]byte, error) {
	result := values
	if manage != "exact" {
		cur, _ := y.parse(existing)
		result = deepMerge(cur, values)
	}
	return yaml.Marshal(result)
}

// deepMerge overlays b onto a recursively (b wins), returning a new map.
func deepMerge(a, b map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		if bm, ok := v.(map[string]any); ok {
			if am, ok := out[k].(map[string]any); ok {
				out[k] = deepMerge(am, bm)
				continue
			}
		}
		out[k] = v
	}
	return out
}
