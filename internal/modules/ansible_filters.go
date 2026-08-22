package modules

import (
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	stdjson "encoding/json"
	"fmt"
	"hash"
	"net"
	"path"
	"regexp"
	"strings"
	"sync"

	"github.com/nikolalohinski/gonja/v2"
	"github.com/nikolalohinski/gonja/v2/exec"
	"gopkg.in/yaml.v3"
)

// hashString computes a hex digest with the named algorithm — the subset of Ansible's `hash` filter
// that is meaningful in a config file. An unknown algorithm is an error, never a silent wrong digest.
func hashString(algo, s string) (string, error) {
	var h hash.Hash
	switch algo {
	case "sha1":
		h = sha1.New()
	case "sha256":
		h = sha256.New()
	case "sha512":
		h = sha512.New()
	case "md5":
		h = md5.New()
	default:
		return "", fmt.Errorf("unsupported hash algorithm %q (use sha1/sha256/sha512/md5)", algo)
	}
	h.Write([]byte(s))
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Ansible filter parity for the template engine.
//
// The templates in configs/config_templates are NATIVE ANSIBLE templates — this agent is simply a
// faster Ansible for rendering them, so it has to understand what Ansible understands. gonja ships
// Jinja2's own filters but none of Ansible's extensions, and 46 shipped templates already use them
// (to_json ×25, ternary ×11, dict2items ×3, b64encode/mandatory ×2, to_yaml/to_nice_yaml/regex_replace
// ×1) — those could not render here at all before this file existed.
//
// Two filters deliberately return an ERROR instead of a value:
//
//   - password_hash — correct output needs sha512-crypt/passlib, which Go's stdlib has not. Emitting
//     anything else would silently write a bogus password hash into a real config. Failing loudly is
//     the safe behaviour; no shipped template uses it.
//   - ipaddr with arguments — Ansible's ipaddr is a large netaddr-backed query language. The bare
//     form (validate / pass through) is implemented faithfully; an argument we do not implement
//     errors rather than guessing.
//
// Everything else follows Ansible's documented semantics.

var registerAnsibleFiltersOnce sync.Once

// RegisterAnsibleFilters adds Ansible's filters to gonja's default environment. Idempotent (safe to
// call from several places) and safe against gonja gaining a filter of the same name later: an
// already-registered name is left alone rather than overwritten.
func RegisterAnsibleFilters() {
	registerAnsibleFiltersOnce.Do(func() {
		for name, fn := range ansibleFilters() {
			if !gonja.DefaultEnvironment.Filters.Exists(name) {
				_ = gonja.DefaultEnvironment.Filters.Register(name, fn)
			}
		}
	})
}

func ansibleFilters() map[string]exec.FilterFunction {
	return map[string]exec.FilterFunction{
		"ternary":       filterTernary,
		"bool":          filterAnsibleBool,
		"mandatory":     filterMandatory,
		"to_json":       filterAnsibleToJSON(false),
		"to_nice_json":  filterAnsibleToJSON(true),
		"from_json":     filterFromJSON,
		"to_yaml":       filterToYAML(false),
		"to_nice_yaml":  filterToYAML(true),
		"from_yaml":     filterFromYAML,
		"combine":       filterCombine,
		"dict2items":    filterDict2Items,
		"items2dict":    filterItems2Dict,
		"regex_replace": filterRegexReplace,
		"regex_search":  filterRegexSearch,
		"regex_findall": filterRegexFindall,
		"b64encode":     filterB64Encode,
		"b64decode":     filterB64Decode,
		"quote":         filterQuote,
		"comment":       filterComment,
		"hash":          filterHash,
		"password_hash": filterPasswordHash,
		"ipaddr":        filterIPAddr,
		"zip":           filterZip,
		"product":       filterProduct,
		// PATH AND SHAPE FILTERS THE GENERATED LIBRARY USES. Measured on the render ratchet: seven templates
		// fail with "unable to evaluate filter" naming exactly these — dirname (3), basename, count, yes_no,
		// required. Adding a filter cannot change what an existing template writes: until now every use of
		// them was an error, so the only possible outcome is that those seven start working.
		"dirname":  filterDirname,
		"basename": filterBasename,
		"count":    filterCount,
		"yes_no":   filterYesNo,
		"required": filterMandatory, // Ansible spells it `mandatory`; the same rule, another name
	}
}

// dirname / basename: path.Dir and path.Base, which is what a config template means by them —
// `{{ pidfile | dirname }}` to create the directory a daemon writes into.
func filterDirname(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	return exec.AsValue(path.Dir(in.String()))
}

func filterBasename(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	return exec.AsValue(path.Base(in.String()))
}

// count: Jinja's `length` under Ansible's name. A list, a map or a string — anything with a size.
func filterCount(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	return exec.AsValue(in.Len())
}

// yes_no: a boolean as the word a config file wants. Defaults to yes/no, and takes the pair as an
// argument ("true,false" / "on,off"), because a file that wants `on` must not be written `yes`.
func filterYesNo(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	yes, no := "yes", "no"
	if a := arg(params, 0); a != nil && a.String() != "" {
		parts := strings.SplitN(a.String(), ",", 2)
		yes = strings.TrimSpace(parts[0])
		if len(parts) > 1 {
			no = strings.TrimSpace(parts[1])
		}
	}
	if in.IsTrue() {
		return exec.AsValue(yes)
	}
	return exec.AsValue(no)
}

func filterErr(format string, a ...any) *exec.Value {
	return exec.AsValue(exec.ErrInvalidCall(fmt.Errorf(format, a...)))
}

// arg returns the i-th positional argument, or nil when absent.
func arg(params *exec.VarArgs, i int) *exec.Value {
	if params == nil || i >= len(params.Args) {
		return nil
	}
	return params.Args[i]
}

func kwarg(params *exec.VarArgs, name string) *exec.Value {
	if params == nil || params.KwArgs == nil {
		return nil
	}
	return params.KwArgs[name]
}

// ternary: `cond | ternary(a, b)` → a when cond is truthy, else b. With a third argument, a None/nil
// condition yields that instead of b — Ansible's documented three-way form.
func filterTernary(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	t, f := arg(params, 0), arg(params, 1)
	if t == nil || f == nil {
		return filterErr("ternary: needs two arguments (true_val, false_val)")
	}
	if none := arg(params, 2); none != nil && in.IsNil() {
		return none
	}
	if in.Bool() {
		return t
	}
	return f
}

// bool: Ansible's string-to-boolean coercion. "yes"/"true"/"on"/"1" are true; everything else false.
func filterAnsibleBool(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	switch strings.ToLower(strings.TrimSpace(in.String())) {
	case "yes", "true", "on", "1", "y", "t":
		return exec.AsValue(true)
	case "no", "false", "off", "0", "n", "f", "":
		return exec.AsValue(false)
	}
	return exec.AsValue(in.Bool())
}

// mandatory: fail when the value is undefined/nil — the opposite of `default`, used to make a missing
// variable a hard error instead of an empty string.
func filterMandatory(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	if in.IsNil() {
		return filterErr("mandatory: variable is undefined")
	}
	return in
}

// to_json / to_nice_json. `nice` indents with 4 spaces, matching Ansible.
func filterAnsibleToJSON(nice bool) exec.FilterFunction {
	return func(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
		if in.IsError() {
			return in
		}
		indent := ""
		if nice {
			indent = "    "
		}
		// An explicit indent= wins, so to_json(indent=2) behaves as documented.
		if iv := kwarg(params, "indent"); iv != nil && !iv.IsNil() {
			indent = strings.Repeat(" ", iv.Integer())
		}
		var (
			b   []byte
			err error
		)
		if indent == "" {
			b, err = stdjson.Marshal(in.Interface())
		} else {
			b, err = stdjson.MarshalIndent(in.Interface(), "", indent)
		}
		if err != nil {
			return filterErr("to_json: %v", err)
		}
		return exec.AsValue(string(b))
	}
}

func filterFromJSON(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	var out any
	if err := stdjson.Unmarshal([]byte(in.String()), &out); err != nil {
		return filterErr("from_json: %v", err)
	}
	return exec.AsValue(out)
}

// to_yaml / to_nice_yaml. Ansible's nice form is indent 2 and no document separator; yaml.v3's default
// marshal already matches closely enough for config rendering.
func filterToYAML(nice bool) exec.FilterFunction {
	return func(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
		if in.IsError() {
			return in
		}
		indent := 2
		if !nice {
			indent = 2 // yaml.v3 requires >0; to_yaml and to_nice_yaml differ only in Ansible's width defaults
		}
		if iv := kwarg(params, "indent"); iv != nil && !iv.IsNil() {
			indent = iv.Integer()
		}
		var sb strings.Builder
		enc := yaml.NewEncoder(&sb)
		enc.SetIndent(indent)
		if err := enc.Encode(in.Interface()); err != nil {
			return filterErr("to_yaml: %v", err)
		}
		_ = enc.Close()
		return exec.AsValue(sb.String())
	}
}

func filterFromYAML(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	var out any
	if err := yaml.Unmarshal([]byte(in.String()), &out); err != nil {
		return filterErr("from_yaml: %v", err)
	}
	return exec.AsValue(out)
}

// combine: merge dicts, right-hand wins. `recursive=true` merges nested dicts instead of replacing
// them — Ansible's documented behaviour.
func filterCombine(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	base, ok := in.Interface().(map[string]any)
	if !ok {
		return filterErr("combine: input is not a dict")
	}
	recursive := false
	if rv := kwarg(params, "recursive"); rv != nil {
		recursive = rv.Bool()
	}
	out := copyMap(base)
	for i := 0; i < len(params.Args); i++ {
		other, ok := params.Args[i].Interface().(map[string]any)
		if !ok {
			return filterErr("combine: argument %d is not a dict", i+1)
		}
		out = mergeMaps(out, other, recursive)
	}
	return exec.AsValue(out)
}

func copyMap(m map[string]any) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func mergeMaps(dst, src map[string]any, recursive bool) map[string]any {
	out := copyMap(dst)
	for k, v := range src {
		if recursive {
			if sub, ok := v.(map[string]any); ok {
				if existing, ok2 := out[k].(map[string]any); ok2 {
					out[k] = mergeMaps(existing, sub, true)
					continue
				}
			}
		}
		out[k] = v
	}
	return out
}

// dict2items: {a: 1} → [{key: a, value: 1}]. Key names are configurable, as in Ansible.
func filterDict2Items(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	if !in.IsDict() {
		return filterErr("dict2items: input is not a dict")
	}
	keyName, valName := "key", "value"
	if v := arg(params, 0); v != nil {
		keyName = v.String()
	} else if v := kwarg(params, "key_name"); v != nil {
		keyName = v.String()
	}
	if v := arg(params, 1); v != nil {
		valName = v.String()
	} else if v := kwarg(params, "value_name"); v != nil {
		valName = v.String()
	}
	out := make([]any, 0, in.Len())
	for _, p := range in.Items() {
		out = append(out, map[string]any{keyName: p.Key.Interface(), valName: p.Value.Interface()})
	}
	return exec.AsValue(out)
}

// items2dict: the inverse of dict2items.
func filterItems2Dict(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	items, ok := in.Interface().([]any)
	if !ok {
		return filterErr("items2dict: input is not a list")
	}
	keyName, valName := "key", "value"
	if v := kwarg(params, "key_name"); v != nil {
		keyName = v.String()
	}
	if v := kwarg(params, "value_name"); v != nil {
		valName = v.String()
	}
	out := map[string]any{}
	for i, it := range items {
		m, ok := it.(map[string]any)
		if !ok {
			return filterErr("items2dict: element %d is not a dict", i)
		}
		k, ok := m[keyName]
		if !ok {
			return filterErr("items2dict: element %d has no %q", i, keyName)
		}
		out[fmt.Sprint(k)] = m[valName]
	}
	return exec.AsValue(out)
}

// regex_replace: Python-style backreferences (\1) are translated to Go's ($1), so the Ansible idiom
// `regex_replace('^(.*)$', '\\1')` works here too.
func filterRegexReplace(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	pat, repl := arg(params, 0), arg(params, 1)
	if pat == nil || repl == nil {
		return filterErr("regex_replace: needs a pattern and a replacement")
	}
	re, err := regexp.Compile(pat.String())
	if err != nil {
		return filterErr("regex_replace: bad pattern %q: %v", pat.String(), err)
	}
	return exec.AsValue(re.ReplaceAllString(in.String(), pythonRefsToGo(repl.String())))
}

var pyBackref = regexp.MustCompile(`\\(\d)`)

func pythonRefsToGo(s string) string { return pyBackref.ReplaceAllString(s, "$$$1") }

func filterRegexSearch(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	pat := arg(params, 0)
	if pat == nil {
		return filterErr("regex_search: needs a pattern")
	}
	re, err := regexp.Compile(pat.String())
	if err != nil {
		return filterErr("regex_search: bad pattern %q: %v", pat.String(), err)
	}
	m := re.FindStringSubmatch(in.String())
	if m == nil {
		// Ansible returns None when nothing matches, which templates test with `is none`/`| default`.
		return exec.AsValue(nil)
	}
	if len(m) > 1 {
		return exec.AsValue(m[1])
	}
	return exec.AsValue(m[0])
}

func filterRegexFindall(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	pat := arg(params, 0)
	if pat == nil {
		return filterErr("regex_findall: needs a pattern")
	}
	re, err := regexp.Compile(pat.String())
	if err != nil {
		return filterErr("regex_findall: bad pattern %q: %v", pat.String(), err)
	}
	found := re.FindAllString(in.String(), -1)
	out := make([]any, 0, len(found))
	for _, f := range found {
		out = append(out, f)
	}
	return exec.AsValue(out)
}

func filterB64Encode(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	return exec.AsValue(base64.StdEncoding.EncodeToString([]byte(in.String())))
}

func filterB64Decode(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	b, err := base64.StdEncoding.DecodeString(in.String())
	if err != nil {
		return filterErr("b64decode: %v", err)
	}
	return exec.AsValue(string(b))
}

// quote: shell-safe single quoting, as Ansible's `quote` (shlex.quote) does.
func filterQuote(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	return exec.AsValue("'" + strings.ReplaceAll(in.String(), "'", `'\''`) + "'")
}

// comment: wrap text as a comment block. Ansible's default style is a decorated C-ish block; the
// styles that matter for config files are plain (#) and the named variants.
func filterComment(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	style := "plain"
	if v := arg(params, 0); v != nil {
		style = v.String()
	}
	prefix := "#"
	switch style {
	case "plain", "sh", "yaml", "ini", "python":
		prefix = "#"
	case "c", "cblock", "java", "php":
		prefix = "//"
	case "xml", "html":
		prefix = "<!--"
	case "erlang":
		prefix = "%"
	default:
		return filterErr("comment: unsupported style %q", style)
	}
	lines := strings.Split(strings.TrimRight(in.String(), "\n"), "\n")
	for i, l := range lines {
		if prefix == "<!--" {
			lines[i] = "<!-- " + l + " -->"
			continue
		}
		lines[i] = prefix + " " + l
	}
	return exec.AsValue(strings.Join(lines, "\n"))
}

// hash: sha1 by default, sha256/sha512/md5 on request — the algorithms Ansible's `hash` exposes that
// are meaningful in a config file.
func filterHash(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	algo := "sha1"
	if v := arg(params, 0); v != nil {
		algo = strings.ToLower(v.String())
	}
	sum, err := hashString(algo, in.String())
	if err != nil {
		return filterErr("hash: %v", err)
	}
	return exec.AsValue(sum)
}

// password_hash deliberately fails. See the file header: a wrong hash silently written into a real
// config is worse than a loud failure, and Go's stdlib has no sha512-crypt.
func filterPasswordHash(_ *exec.Evaluator, in *exec.Value, _ *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	return filterErr("password_hash is not supported by this engine — precompute the hash and pass it " +
		"as a value (emitting a different hash would silently write a wrong password)")
}

// ipaddr: the bare form validates and passes an IP/CIDR through, returning false for anything else —
// Ansible's own behaviour for `value | ipaddr`. Arguments are refused rather than approximated.
func filterIPAddr(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	if len(params.Args) > 0 {
		return filterErr("ipaddr(%q) is not supported by this engine — only the bare `| ipaddr` "+
			"validation form is", params.Args[0].String())
	}
	s := strings.TrimSpace(in.String())
	if ip := net.ParseIP(s); ip != nil {
		return exec.AsValue(s)
	}
	if _, _, err := net.ParseCIDR(s); err == nil {
		return exec.AsValue(s)
	}
	return exec.AsValue(false)
}

// zip: pair up lists, stopping at the shortest — Python/Ansible semantics.
func filterZip(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	lists := [][]any{}
	first, ok := in.Interface().([]any)
	if !ok {
		return filterErr("zip: input is not a list")
	}
	lists = append(lists, first)
	for i := range params.Args {
		l, ok := params.Args[i].Interface().([]any)
		if !ok {
			return filterErr("zip: argument %d is not a list", i+1)
		}
		lists = append(lists, l)
	}
	shortest := len(lists[0])
	for _, l := range lists[1:] {
		if len(l) < shortest {
			shortest = len(l)
		}
	}
	out := make([]any, 0, shortest)
	for i := 0; i < shortest; i++ {
		row := make([]any, 0, len(lists))
		for _, l := range lists {
			row = append(row, l[i])
		}
		out = append(out, row)
	}
	return exec.AsValue(out)
}

// product: cartesian product of the input list with the argument lists.
func filterProduct(_ *exec.Evaluator, in *exec.Value, params *exec.VarArgs) *exec.Value {
	if in.IsError() {
		return in
	}
	first, ok := in.Interface().([]any)
	if !ok {
		return filterErr("product: input is not a list")
	}
	rows := make([][]any, 0, len(first))
	for _, v := range first {
		rows = append(rows, []any{v})
	}
	for i := range params.Args {
		l, ok := params.Args[i].Interface().([]any)
		if !ok {
			return filterErr("product: argument %d is not a list", i+1)
		}
		next := make([][]any, 0, len(rows)*len(l))
		for _, r := range rows {
			for _, v := range l {
				row := append(append([]any{}, r...), v)
				next = append(next, row)
			}
		}
		rows = next
	}
	out := make([]any, 0, len(rows))
	for _, r := range rows {
		out = append(out, r)
	}
	return exec.AsValue(out)
}
