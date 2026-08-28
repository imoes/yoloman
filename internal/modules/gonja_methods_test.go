package modules

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// WHICH Python methods can the renderer actually execute?
//
// find_renderer_gaps.py assumed none of them and reported 125 templates as latent failures. The assumption
// was never tested against the engine — it was inferred from five templates that fail for other reasons, and
// it was wrong for seven of the nine methods it listed. MEASURED against gonja v1.5.3:
//
//	execute fine : items, keys, append, split, join, upper, strip, format
//	fail         : get, values  ("unknown method 'get' for '{...}'")
//
// So this test is the observation point for that list, and the list in find_renderer_gaps.py must not be
// written by hand again. A gonja upgrade that changes the answer fails here first.
//
// One subtlety worth keeping: `{% if x.get('k') is defined %}` does NOT fail — `is defined` swallows the
// error and the guard reads false. That is why the gap is latent even in a template whose sample DOES supply
// the value: the branch silently never fires, and the file renders without the setting.
func TestWhichMethodsGonjaExecutes(t *testing.T) {
	cases := map[string]string{
		"get":            `{{ d.get('a') }}`,
		"get-default":    `{{ d.get('missing', 'fallback') }}`,
		"items":          `{% for k, v in d.items() %}{{ k }}={{ v }} {% endfor %}`,
		"keys":           `{{ d.keys() }}`,
		"values":         `{{ d.values() }}`,
		"append":         `{% set l = [] %}{% set _ = l.append('x') %}{{ l }}`,
		"split":          `{{ s.split(',') }}`,
		"join":           `{{ ','.join(['a','b']) }}`,
		"upper":          `{{ s.upper() }}`,
		"strip":          `{{ s.strip() }}`,
		"format":         `{{ '%s' | format(s) }}`,
		"attr-on-map":    `{{ d.a }}`,
		"index-on-map":   `{{ d['a'] }}`,
		"undefined-attr": `{{ d.nope | default('dflt') }}`,
	}
	dir := t.TempDir()
	for name, body := range cases {
		tpl := filepath.Join(dir, name+".j2")
		if err := os.WriteFile(tpl, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		res, err := NewTemplateRender().Run(context.Background(), map[string]any{
			"template_path": tpl,
			"dest":          filepath.Join(dir, name+".out"),
			"values":        map[string]any{"d": map[string]any{"a": "1", "b": "2"}, "s": "x,y"},
		}, false)
		if err != nil {
			t.Logf("%-15s FAILS: %v", name, err)
			continue
		}
		out, _ := res.Data.(map[string]any)["rendered"].(string)
		t.Logf("%-15s ok  -> %q", name, out)
	}
}
