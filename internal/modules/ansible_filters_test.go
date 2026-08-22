package modules

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
)

// render is a small helper: render `tmpl` with `values` through the real module (which registers the
// Ansible filters) and return the output, failing the test on a render error.
func renderTmpl(t *testing.T, tmpl string, values map[string]any) string {
	t.Helper()
	dest := filepath.Join(t.TempDir(), "out")
	res, err := NewTemplateRender().Run(context.Background(), map[string]any{"template": tmpl, "dest": dest, "values": values}, false)
	if err != nil {
		t.Fatalf("render %q: %v", tmpl, err)
	}
	return res.Data.(map[string]any)["rendered"].(string)
}

// renderErr asserts that rendering FAILS (the filter refused rather than emitting a wrong value).
func renderErr(t *testing.T, tmpl string, values map[string]any) string {
	t.Helper()
	dest := filepath.Join(t.TempDir(), "out")
	_, err := NewTemplateRender().Run(context.Background(), map[string]any{"template": tmpl, "dest": dest, "values": values}, false)
	if err == nil {
		t.Fatalf("expected %q to fail, but it rendered", tmpl)
	}
	return err.Error()
}

func TestAnsibleFilters_Ternary(t *testing.T) {
	if got := renderTmpl(t, "{{ flag | ternary('on','off') }}", map[string]any{"flag": true}); got != "on" {
		t.Errorf("ternary true = %q, want on", got)
	}
	if got := renderTmpl(t, "{{ flag | ternary('on','off') }}", map[string]any{"flag": false}); got != "off" {
		t.Errorf("ternary false = %q, want off", got)
	}
	// three-arg form: nil condition takes the third value.
	if got := renderTmpl(t, "{{ x | ternary('y','n','maybe') }}", map[string]any{"x": nil}); got != "maybe" {
		t.Errorf("ternary nil = %q, want maybe", got)
	}
}

func TestAnsibleFilters_Bool(t *testing.T) {
	for in, want := range map[string]string{"yes": "True", "no": "False", "on": "True", "1": "True", "0": "False"} {
		if got := renderTmpl(t, "{{ v | bool }}", map[string]any{"v": in}); got != want {
			t.Errorf("bool(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAnsibleFilters_Mandatory(t *testing.T) {
	if got := renderTmpl(t, "{{ v | mandatory }}", map[string]any{"v": "x"}); got != "x" {
		t.Errorf("mandatory(set) = %q", got)
	}
	if msg := renderErr(t, "{{ missing | mandatory }}", map[string]any{}); !strings.Contains(msg, "mandatory") {
		t.Errorf("mandatory(undefined) error = %q", msg)
	}
}

func TestAnsibleFilters_ToJSON(t *testing.T) {
	got := renderTmpl(t, "{{ d | to_json }}", map[string]any{"d": map[string]any{"a": 1}})
	if got != `{"a":1}` {
		t.Errorf("to_json = %q", got)
	}
	nice := renderTmpl(t, "{{ d | to_nice_json }}", map[string]any{"d": map[string]any{"a": 1}})
	if !strings.Contains(nice, "\n    \"a\": 1") {
		t.Errorf("to_nice_json not 4-space indented: %q", nice)
	}
}

func TestAnsibleFilters_FromJSONRoundTrip(t *testing.T) {
	got := renderTmpl(t, `{{ (s | from_json).name }}`, map[string]any{"s": `{"name":"pg"}`})
	if got != "pg" {
		t.Errorf("from_json.name = %q, want pg", got)
	}
}

func TestAnsibleFilters_Dict2ItemsAndBack(t *testing.T) {
	// dict2items → iterate → the key/value names are the defaults.
	got := renderTmpl(t, "{% for i in d | dict2items %}{{ i.key }}={{ i.value }};{% endfor %}",
		map[string]any{"d": map[string]any{"host": "db1"}})
	if got != "host=db1;" {
		t.Errorf("dict2items = %q", got)
	}
	// items2dict inverse.
	got = renderTmpl(t, `{{ (items | items2dict).host }}`,
		map[string]any{"items": []any{map[string]any{"key": "host", "value": "db1"}}})
	if got != "db1" {
		t.Errorf("items2dict.host = %q, want db1", got)
	}
}

func TestAnsibleFilters_Combine(t *testing.T) {
	got := renderTmpl(t, `{{ (a | combine(b)).port }}`,
		map[string]any{"a": map[string]any{"host": "x", "port": 1}, "b": map[string]any{"port": 5432}})
	if got != "5432" {
		t.Errorf("combine right-wins = %q, want 5432", got)
	}
}

func TestAnsibleFilters_RegexReplaceBackref(t *testing.T) {
	// The Ansible idiom with a \1 backreference. The backslash must be escaped in the string literal
	// (`\\1`) — gonja's lexer, like Jinja2's, treats a bare `\1` as an invalid escape. The filter then
	// receives `\1` and translates it to Go's $1.
	got := renderTmpl(t, `{{ s | regex_replace('^user_(.*)$', 'db_\\1') }}`, map[string]any{"s": "user_name"})
	if got != "db_name" {
		t.Errorf("regex_replace backref = %q, want db_name", got)
	}
}

func TestAnsibleFilters_RegexSearchNoneOnMiss(t *testing.T) {
	// A miss returns None, which `| default` catches — the Ansible pattern.
	got := renderTmpl(t, `{{ s | regex_search('[0-9]+') | default('none') }}`, map[string]any{"s": "abc"})
	if got != "none" {
		t.Errorf("regex_search miss = %q, want none", got)
	}
}

func TestAnsibleFilters_B64(t *testing.T) {
	if got := renderTmpl(t, "{{ s | b64encode }}", map[string]any{"s": "hi"}); got != "aGk=" {
		t.Errorf("b64encode = %q", got)
	}
	if got := renderTmpl(t, "{{ s | b64decode }}", map[string]any{"s": "aGk="}); got != "hi" {
		t.Errorf("b64decode = %q", got)
	}
}

func TestAnsibleFilters_Quote(t *testing.T) {
	if got := renderTmpl(t, "{{ s | quote }}", map[string]any{"s": "a b"}); got != "'a b'" {
		t.Errorf("quote = %q", got)
	}
}

func TestAnsibleFilters_Hash(t *testing.T) {
	// sha1 of "" is the well-known da39a3ee… — pins that the default algorithm is sha1.
	if got := renderTmpl(t, "{{ '' | hash }}", map[string]any{}); got != "da39a3ee5e6b4b0d3255bfef95601890afd80709" {
		t.Errorf("hash default sha1 = %q", got)
	}
}

func TestAnsibleFilters_ToYAML(t *testing.T) {
	got := renderTmpl(t, "{{ d | to_yaml }}", map[string]any{"d": map[string]any{"port": 5432}})
	if !strings.Contains(got, "port: 5432") {
		t.Errorf("to_yaml = %q", got)
	}
}

func TestAnsibleFilters_IPAddrValidation(t *testing.T) {
	if got := renderTmpl(t, "{{ ip | ipaddr }}", map[string]any{"ip": "10.0.0.1"}); got != "10.0.0.1" {
		t.Errorf("ipaddr(valid) = %q", got)
	}
	if got := renderTmpl(t, "{{ ip | ipaddr }}", map[string]any{"ip": "nope"}); got != "False" {
		t.Errorf("ipaddr(invalid) = %q, want False", got)
	}
}

// The two deliberate refusals: they must FAIL loudly, never emit a plausible-but-wrong value.
func TestAnsibleFilters_PasswordHashRefuses(t *testing.T) {
	if msg := renderErr(t, "{{ p | password_hash('sha512') }}", map[string]any{"p": "secret"}); !strings.Contains(msg, "password_hash") {
		t.Errorf("password_hash error = %q", msg)
	}
}

func TestAnsibleFilters_IPAddrArgRefuses(t *testing.T) {
	if msg := renderErr(t, "{{ ip | ipaddr('address') }}", map[string]any{"ip": "10.0.0.1/24"}); !strings.Contains(msg, "ipaddr") {
		t.Errorf("ipaddr(arg) error = %q", msg)
	}
}

func TestAnsibleFilters_ZipAndProduct(t *testing.T) {
	got := renderTmpl(t, "{% for a,b in xs | zip(ys) %}{{ a }}:{{ b }};{% endfor %}",
		map[string]any{"xs": []any{1, 2}, "ys": []any{"a", "b"}})
	if got != "1:a;2:b;" {
		t.Errorf("zip = %q", got)
	}
}

// TestPathAndShapeFilters pins the five filters the generated library needs and gonja does not ship.
// Measured on the render ratchet before they existed: seven templates failed with "unable to evaluate
// filter" naming exactly these, and adding them could not change any other template's output — every use of
// them had been an error, so the only possible effect was those seven starting to work.
func TestPathAndShapeFilters(t *testing.T) {
	values := map[string]any{"items": []any{1, 2, 3}, "flag": true, "nope": false}
	cases := []struct{ tmpl, want string }{
		{`{{ "/var/run/x.pid" | dirname }}`, "/var/run"},
		{`{{ "/var/run/x.pid" | basename }}`, "x.pid"},
		{`{{ items | count }}`, "3"},
		{`{{ flag | yes_no }}`, "yes"},
		{`{{ nope | yes_no }}`, "no"},
		// A file that wants `on` must not be written `yes` — hence the pair as an argument.
		{`{{ flag | yes_no("on,off") }}`, "on"},
		{`{{ nope | yes_no("true,false") }}`, "false"},
		// dirname of a bare name is "." (path.Dir). Pinned so nobody "fixes" it to an empty string.
		{`{{ "x.conf" | dirname }}`, "."},
	}
	for _, c := range cases {
		if got := renderTmpl(t, c.tmpl, values); got != c.want {
			t.Errorf("%s = %q, want %q", c.tmpl, got, c.want)
		}
	}
}
