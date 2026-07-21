package modules

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/clbanning/mxj/v2"
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
		"format":    stringEnumProp("Config codec.", "keyvalue", "ini", "json", "yaml", "xml"),
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
	case "ini":
		com, _ := params["comment"].(string)
		if com == "" {
			com = "#"
		}
		return &iniCodec{comment: com}, nil
	case "xml":
		return &xmlCodec{}, nil
	case "fstab":
		return &fstabCodec{}, nil
	case "zonefile":
		return &zonefileCodec{}, nil
	case "exports":
		return &exportsCodec{}, nil
	default:
		return nil, fmt.Errorf("config: unsupported format %q (want keyvalue|ini|json|yaml|xml|fstab|zonefile|exports)", format)
	}
}

// fstabCodec handles the columnar /etc/fstab table (and fstab-shaped files like
// /etc/mtab): six whitespace-separated fields per line — device, mountpoint,
// fstype, options, dump, pass. Unlike keyvalue/ini there is no unique scalar
// key (swap entries repeat "none"/"swap"), so it parses to a LIST of records
// under "entries" rather than a flat map — the config-value model allows a
// nested/list shape. render() rewrites the whole table (comments in the leading
// header are preserved; the entry block is regenerated, column-aligned).
type fstabCodec struct{}

func (c *fstabCodec) parse(data []byte) (map[string]any, error) {
	entries := []any{}
	for _, line := range strings.Split(string(data), "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		f := strings.Fields(t)
		if len(f) < 3 {
			continue // not a valid mount entry
		}
		e := map[string]any{
			"device": f[0], "mountpoint": f[1], "fstype": f[2],
			"options": "defaults", "dump": "0", "pass": "0",
		}
		if len(f) >= 4 {
			e["options"] = f[3]
		}
		if len(f) >= 5 {
			e["dump"] = f[4]
		}
		if len(f) >= 6 {
			e["pass"] = f[5]
		}
		entries = append(entries, e)
	}
	return map[string]any{"entries": entries}, nil
}

func (c *fstabCodec) render(existing []byte, values map[string]any, _ string) ([]byte, error) {
	// Preserve the leading comment/blank header (the "# <file system> <mount
	// point> ..." block people rely on) verbatim; regenerate the entry table.
	var header []string
	for _, line := range strings.Split(string(existing), "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			header = append(header, line)
		} else {
			break
		}
	}

	get := func(m map[string]any, k, def string) string {
		if v, ok := m[k]; ok && v != nil {
			s := fmt.Sprintf("%v", v)
			if s != "" {
				return s
			}
		}
		return def
	}
	type row struct{ dev, mp, fs, opt, dump, pass string }
	var rows []row
	if raw, ok := values["entries"].([]any); ok {
		for _, item := range raw {
			m, ok := item.(map[string]any)
			if !ok {
				continue
			}
			r := row{
				dev: get(m, "device", ""), mp: get(m, "mountpoint", ""), fs: get(m, "fstype", ""),
				opt: get(m, "options", "defaults"), dump: get(m, "dump", "0"), pass: get(m, "pass", "0"),
			}
			if r.dev == "" || r.mp == "" || r.fs == "" {
				continue // skip incomplete rows rather than emit a broken fstab line
			}
			rows = append(rows, r)
		}
	}

	// Column widths for readable alignment (device/mountpoint/fstype/options).
	w := [4]int{}
	upd := func(i, n int) {
		if n > w[i] {
			w[i] = n
		}
	}
	for _, r := range rows {
		upd(0, len(r.dev))
		upd(1, len(r.mp))
		upd(2, len(r.fs))
		upd(3, len(r.opt))
	}

	var b strings.Builder
	for _, h := range header {
		b.WriteString(h)
		b.WriteByte('\n')
	}
	for _, r := range rows {
		fmt.Fprintf(&b, "%-*s  %-*s  %-*s  %-*s  %s  %s\n", w[0], r.dev, w[1], r.mp, w[2], r.fs, w[3], r.opt, r.dump, r.pass)
	}
	return []byte(b.String()), nil
}

// zonefileCodec handles a BIND/RFC-1035 DNS zone file: line-oriented resource
// records `[owner] [ttl] [class] type rdata`, plus the `$TTL`/`$ORIGIN`
// directives. Like fstab there is no unique scalar key (many records share an
// owner), so it parses to a LIST under "records" (each {name,ttl,class,type,
// data}) with $TTL/$ORIGIN as top-level scalars. Pragmatic subset: strips `;`
// comments, collapses `( … )` multi-line rdata (SOA) onto one logical line, and
// inherits the previous owner when a record line starts with whitespace.
// render() regenerates the record block (leading `;` comment header preserved),
// emitting an explicit owner + class per line (always valid). Good enough to
// add/edit/remove records; not a byte-exact formatter.
type zonefileCodec struct{}

var _zoneClasses = map[string]bool{"IN": true, "CH": true, "HS": true, "CS": true}

type zoneLogicalLine struct {
	text        string
	startsBlank bool
}

func stripZoneComment(line string) string {
	if i := strings.IndexByte(line, ';'); i >= 0 {
		return line[:i]
	}
	return line
}

// splitZoneLines yields logical lines: comments removed, parenthesised groups
// joined, parens flattened to spaces. startsBlank marks a record whose first
// physical line began with whitespace (owner inherited from the previous one).
func splitZoneLines(s string) []zoneLogicalLine {
	var out []zoneLogicalLine
	var buf strings.Builder
	depth := 0
	startsBlank := false
	started := false
	for _, raw := range strings.Split(s, "\n") {
		line := stripZoneComment(raw)
		if !started {
			startsBlank = len(line) > 0 && (line[0] == ' ' || line[0] == '\t')
		}
		for _, ch := range line {
			if ch == '(' {
				depth++
			} else if ch == ')' {
				depth--
			}
		}
		if buf.Len() > 0 {
			buf.WriteByte(' ')
		}
		buf.WriteString(strings.TrimSpace(line))
		started = true
		if depth <= 0 {
			txt := strings.ReplaceAll(buf.String(), "(", " ")
			txt = strings.ReplaceAll(txt, ")", " ")
			txt = strings.Join(strings.Fields(txt), " ")
			if txt != "" {
				out = append(out, zoneLogicalLine{text: txt, startsBlank: startsBlank})
			}
			buf.Reset()
			started = false
			depth = 0
		}
	}
	return out
}

func zoneAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func (z *zonefileCodec) parse(data []byte) (map[string]any, error) {
	out := map[string]any{}
	records := []any{}
	var ttl, origin string
	lastName := ""
	for _, ll := range splitZoneLines(string(data)) {
		f := strings.Fields(ll.text)
		if len(f) == 0 {
			continue
		}
		if strings.HasPrefix(f[0], "$") {
			up := strings.ToUpper(f[0])
			if up == "$TTL" && len(f) >= 2 {
				ttl = f[1]
			} else if up == "$ORIGIN" && len(f) >= 2 {
				origin = f[1]
			}
			continue // other directives ($INCLUDE, $GENERATE) are left out of the model
		}
		name := ""
		idx := 0
		if ll.startsBlank {
			name = lastName
		} else {
			name = f[0]
			idx = 1
			lastName = name
		}
		rttl, rclass, rtype := "", "", ""
		for idx < len(f) {
			tok := f[idx]
			if rttl == "" && zoneAllDigits(tok) {
				rttl = tok
				idx++
				continue
			}
			if rclass == "" && _zoneClasses[strings.ToUpper(tok)] {
				rclass = strings.ToUpper(tok)
				idx++
				continue
			}
			rtype = strings.ToUpper(tok)
			idx++
			break
		}
		if rtype == "" {
			continue // not a record line
		}
		rec := map[string]any{"name": name, "type": rtype, "data": strings.Join(f[idx:], " ")}
		if rttl != "" {
			rec["ttl"] = rttl
		}
		if rclass != "" {
			rec["class"] = rclass
		}
		records = append(records, rec)
	}
	if ttl != "" {
		out["$TTL"] = ttl
	}
	if origin != "" {
		out["$ORIGIN"] = origin
	}
	out["records"] = records
	return out, nil
}

func (z *zonefileCodec) render(existing []byte, values map[string]any, _ string) ([]byte, error) {
	str := func(v any) string {
		if v == nil {
			return ""
		}
		return strings.TrimSpace(fmt.Sprintf("%v", v))
	}
	var b strings.Builder
	for _, line := range strings.Split(string(existing), "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, ";") {
			b.WriteString(line)
			b.WriteByte('\n')
		} else {
			break
		}
	}
	if v := str(values["$TTL"]); v != "" {
		fmt.Fprintf(&b, "$TTL %s\n", v)
	}
	if v := str(values["$ORIGIN"]); v != "" {
		fmt.Fprintf(&b, "$ORIGIN %s\n", v)
	}
	if raw, ok := values["records"].([]any); ok {
		for _, item := range raw {
			m, ok := item.(map[string]any)
			if !ok {
				continue
			}
			typ := strings.ToUpper(str(m["type"]))
			dat := str(m["data"])
			if typ == "" || dat == "" {
				continue // skip incomplete rows rather than emit a broken RR
			}
			name := str(m["name"])
			if name == "" {
				name = "@"
			}
			class := str(m["class"])
			if class == "" {
				class = "IN"
			}
			parts := []string{name}
			if ttl := str(m["ttl"]); ttl != "" {
				parts = append(parts, ttl)
			}
			parts = append(parts, class, typ, dat)
			b.WriteString(strings.Join(parts, " "))
			b.WriteByte('\n')
		}
	}
	return []byte(b.String()), nil
}

// exportsCodec handles an NFS /etc/exports table: each line is an exported
// path followed by whitespace-separated client(options) specs, e.g.
//   /srv/nfs  192.168.1.0/24(rw,sync,no_subtree_check)  10.0.0.5(ro)
// Like fstab there is no unique scalar key, so it parses to a LIST under
// "exports" of {path, clients} (clients = the raw client(options) spec text,
// which the UI edits as one field). render() regenerates the table (leading
// `#` comment header preserved).
type exportsCodec struct{}

func (c *exportsCodec) parse(data []byte) (map[string]any, error) {
	entries := []any{}
	for _, line := range strings.Split(string(data), "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		f := strings.Fields(t)
		if len(f) < 1 {
			continue
		}
		entries = append(entries, map[string]any{"path": f[0], "clients": strings.Join(f[1:], " ")})
	}
	return map[string]any{"exports": entries}, nil
}

func (c *exportsCodec) render(existing []byte, values map[string]any, _ string) ([]byte, error) {
	str := func(v any) string {
		if v == nil {
			return ""
		}
		return strings.TrimSpace(fmt.Sprintf("%v", v))
	}
	var b strings.Builder
	for _, line := range strings.Split(string(existing), "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.HasPrefix(t, "#") {
			b.WriteString(line)
			b.WriteByte('\n')
		} else {
			break
		}
	}
	if raw, ok := values["exports"].([]any); ok {
		for _, item := range raw {
			m, ok := item.(map[string]any)
			if !ok {
				continue
			}
			path := str(m["path"])
			if path == "" {
				continue
			}
			clients := str(m["clients"])
			if clients != "" {
				fmt.Fprintf(&b, "%s %s\n", path, clients)
			} else {
				fmt.Fprintf(&b, "%s\n", path)
			}
		}
	}
	return []byte(b.String()), nil
}

// xmlCodec round-trips an XML config (e.g. a libvirt domain definition) to/from
// a nested map via mxj. Merge deep-merges into the parsed document; exact emits
// only the given values. Attributes appear as "-name" keys, text as "#text"
// (mxj's convention) — lossy for comments/order but structurally faithful.
type xmlCodec struct{}

func (x *xmlCodec) parse(data []byte) (map[string]any, error) {
	if len(strings.TrimSpace(string(data))) == 0 {
		return map[string]any{}, nil
	}
	mv, err := mxj.NewMapXml(data)
	if err != nil {
		return nil, err
	}
	return map[string]any(mv), nil
}

func (x *xmlCodec) render(existing []byte, values map[string]any, manage string) ([]byte, error) {
	result := values
	if manage != "exact" {
		cur, _ := x.parse(existing)
		result = deepMerge(cur, values)
	}
	out, err := mxj.Map(result).XmlIndent("", "  ")
	if err != nil {
		return nil, err
	}
	return append(out, '\n'), nil
}

// iniCodec handles [section] files of key=value lines. Parsed to a nested
// {section: {key: value}} map (keys before the first header live under the ""
// section). Structure-preserving merge: updates keys in place within their
// section, appends new keys/sections, leaving comments/order untouched.
type iniCodec struct {
	comment string
}

func (c *iniCodec) sectionOf(line string) (string, bool) {
	t := strings.TrimSpace(line)
	if len(t) >= 2 && t[0] == '[' && t[len(t)-1] == ']' {
		return strings.TrimSpace(t[1 : len(t)-1]), true
	}
	return "", false
}

func (c *iniCodec) kv(line string) (key, val string, ok bool) {
	t := strings.TrimSpace(line)
	if t == "" || strings.HasPrefix(t, c.comment) || strings.HasPrefix(t, ";") {
		return "", "", false
	}
	i := strings.Index(t, "=")
	if i < 0 {
		return "", "", false
	}
	return strings.TrimSpace(t[:i]), strings.TrimSpace(t[i+1:]), true
}

func (c *iniCodec) parse(data []byte) (map[string]any, error) {
	out := map[string]any{}
	section := ""
	for _, line := range strings.Split(string(data), "\n") {
		if s, ok := c.sectionOf(line); ok {
			section = s
			if _, exists := out[section]; !exists {
				out[section] = map[string]any{}
			}
			continue
		}
		if key, val, ok := c.kv(line); ok {
			sec, _ := out[section].(map[string]any)
			if sec == nil {
				sec = map[string]any{}
				out[section] = sec
			}
			sec[key] = val
		}
	}
	return out, nil
}

func (c *iniCodec) render(existing []byte, values map[string]any, manage string) ([]byte, error) {
	// desired[section][key] = string; a null value deletes that key (del).
	desired := map[string]map[string]string{}
	del := map[string]map[string]bool{}
	sectionOrder := []string{}
	for sec, kv := range values {
		m, ok := kv.(map[string]any)
		if !ok {
			continue
		}
		desired[sec] = map[string]string{}
		del[sec] = map[string]bool{}
		sectionOrder = append(sectionOrder, sec)
		for k, v := range m {
			if v == nil {
				del[sec][k] = true
				continue
			}
			desired[sec][k] = fmt.Sprintf("%v", v)
		}
	}
	sort.Strings(sectionOrder)

	if manage == "exact" {
		var b strings.Builder
		for _, sec := range sectionOrder {
			if sec != "" {
				b.WriteString("[" + sec + "]\n")
			}
			keys := sortedKeys(desired[sec])
			for _, k := range keys {
				b.WriteString(k + " = " + desired[sec][k] + "\n")
			}
			b.WriteString("\n")
		}
		return []byte(strings.TrimRight(b.String(), "\n") + "\n"), nil
	}

	// merge: rewrite matching keys in place; append the rest per section.
	seen := map[string]map[string]bool{}
	for sec := range desired {
		seen[sec] = map[string]bool{}
	}
	lines := strings.Split(string(existing), "\n")
	trailingNL := len(lines) > 0 && lines[len(lines)-1] == ""
	if trailingNL {
		lines = lines[:len(lines)-1]
	}
	cur := ""
	// track the last line index within each section, to append new keys there
	lastIdx := map[string]int{}
	dropped := map[int]bool{} // lines removed because their key is null (delete)
	for i, line := range lines {
		if s, ok := c.sectionOf(line); ok {
			cur = s
			lastIdx[cur] = i
			continue
		}
		if key, _, ok := c.kv(line); ok {
			lastIdx[cur] = i
			if d, has := del[cur]; has && d[key] {
				dropped[i] = true // null = delete: drop this key's line
				continue
			}
			if want, has := desired[cur]; has {
				if nv, present := want[key]; present && !seen[cur][key] {
					indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
					lines[i] = indent + key + " = " + nv
					seen[cur][key] = true
				}
			}
		}
	}
	// append unseen keys of existing sections + brand-new sections
	appendAfter := map[int][]string{}
	newSections := []string{}
	for _, sec := range sectionOrder {
		if _, exists := lastIdx[sec]; !exists && sec != "" {
			newSections = append(newSections, sec)
			continue
		}
		for _, k := range sortedKeys(desired[sec]) {
			if !seen[sec][k] {
				at := lastIdx[sec]
				appendAfter[at] = append(appendAfter[at], k+" = "+desired[sec][k])
			}
		}
	}
	var out []string
	for i, line := range lines {
		if !dropped[i] {
			out = append(out, line)
		}
		if add, ok := appendAfter[i]; ok {
			out = append(out, add...)
		}
	}
	for _, sec := range newSections {
		out = append(out, "", "["+sec+"]")
		for _, k := range sortedKeys(desired[sec]) {
			out = append(out, k+" = "+desired[sec][k])
		}
	}
	return []byte(strings.Join(out, "\n") + "\n"), nil
}

func sortedKeys(m map[string]string) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
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
	// A null value means "delete this key" (structure-preserving) — the
	// document loop's way to remove a directive without rewriting the file.
	want := map[string]string{}
	del := map[string]bool{}
	for key, v := range values {
		if v == nil {
			del[key] = true
			continue
		}
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

	// merge: rewrite matching lines in place, drop keys set to null, append new.
	seen := map[string]bool{}
	src := strings.Split(string(existing), "\n")
	// A trailing empty element from a final newline: drop it, restore later.
	if len(src) > 0 && src[len(src)-1] == "" {
		src = src[:len(src)-1]
	}
	lines := make([]string, 0, len(src))
	for _, line := range src {
		if key, _, ok := k.splitLine(line); ok {
			if del[key] {
				continue // null = delete: drop the directive line entirely
			}
			if nv, present := want[key]; present && !seen[key] {
				lines = append(lines, k.format(key, nv))
				seen[key] = true
				continue
			}
		}
		lines = append(lines, line)
	}
	appendKeys := make([]string, 0)
	for key := range want {
		if !seen[key] {
			appendKeys = append(appendKeys, key)
		}
	}
	sort.Strings(appendKeys)
	for _, key := range appendKeys {
		lines = append(lines, k.format(key, want[key]))
	}
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
