package modules

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestTemplateRenderJinja2(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "nginx.conf")
	tmpl := "worker_processes {{ workers }};\n" +
		"{% for u in upstreams %}upstream {{ u.name }} { server {{ u.host }}:{{ u.port }}; }\n{% endfor %}" +
		"{% if tls %}listen 443 ssl;{% else %}listen 80;{% endif %}\n"
	values := map[string]any{
		"workers": 4,
		"tls":     true,
		"upstreams": []any{
			map[string]any{"name": "app", "host": "10.0.0.1", "port": 8080},
			map[string]any{"name": "api", "host": "10.0.0.2", "port": 9090},
		},
	}
	res, err := NewTemplateRender().Run(context.Background(), map[string]any{"template": tmpl, "dest": dest, "values": values}, false)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if !res.Changed {
		t.Fatal("expected changed on first render")
	}
	out, _ := os.ReadFile(dest)
	s := string(out)
	for _, want := range []string{"worker_processes 4;", "upstream app { server 10.0.0.1:8080; }", "upstream api { server 10.0.0.2:9090; }", "listen 443 ssl;"} {
		if !strings.Contains(s, want) {
			t.Errorf("rendered output missing %q:\n%s", want, s)
		}
	}
	// idempotent second render.
	res, _ = NewTemplateRender().Run(context.Background(), map[string]any{"template": tmpl, "dest": dest, "values": values}, false)
	if res.Changed {
		t.Error("second identical render should be idempotent")
	}
}

func TestTemplateRenderIntegralFloatsRenderAsInts(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "c.conf")
	// float64 values (as JSON decoding produces) must render as ints.
	res, err := NewTemplateRender().Run(context.Background(), map[string]any{
		"template": "workers {{ w }} port {{ p }}", "dest": dest,
		"values": map[string]any{"w": float64(4), "p": float64(8080)},
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	got := res.Data.(map[string]any)["rendered"].(string)
	if got != "workers 4 port 8080" {
		t.Errorf("integral floats not coerced to ints: %q", got)
	}
}

func TestTemplateRenderDryRun(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "out.conf")
	res, err := NewTemplateRender().Run(context.Background(), map[string]any{"template": "x={{ v }}", "dest": dest, "values": map[string]any{"v": "1"}}, true)
	if err != nil || !res.Changed {
		t.Fatalf("dry-run: changed=%v err=%v", res.Changed, err)
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Error("dry-run must not write the file")
	}
}

// renderTemplateWithSample: render one template dir against its own sample.json. The error is the finding —
// a template that cannot render its own sample is not an editor, whatever else is true about it.
func renderTemplateWithSample(root, name, dest string) error {
	dir := filepath.Join(root, name)
	sampleRaw, err := os.ReadFile(filepath.Join(dir, "sample.json"))
	if err != nil {
		return fmt.Errorf("read sample.json: %w", err)
	}
	var values map[string]any
	if err := json.Unmarshal(sampleRaw, &values); err != nil {
		return fmt.Errorf("parse sample.json: %w", err)
	}
	res, err := NewTemplateRender().Run(context.Background(), map[string]any{
		"template_path": filepath.Join(dir, "template.j2"),
		"dest":          dest,
		"values":        values,
	}, false)
	if err != nil {
		return err
	}
	rendered, _ := res.Data.(map[string]any)["rendered"].(string)
	if len(rendered) == 0 {
		return fmt.Errorf("rendered empty")
	}
	// AND THE OUTPUT HAS TO BE USABLE. The sweep proposed "a list rendered without '- ' breaks YAML" and
	// flagged 1232 templates; only 22 actually target a YAML file, so as stated it was noise. What survives
	// is stronger and does not care how the list is written: if the recorded target is a YAML file, the
	// rendered text must parse. Invalid YAML is still a non-empty string, so the emptiness check above
	// cannot see it — and a whole-file write of unparsable YAML leaves the service unable to read its own
	// config. Measured: 3 of 17 (nextepc_pcrf, pre_commit, sagan-rules).
	target := recordedTarget(root, name)
	if strings.HasSuffix(target, ".yaml") || strings.HasSuffix(target, ".yml") {
		var parsed any
		if err := yaml.Unmarshal([]byte(rendered), &parsed); err != nil {
			return fmt.Errorf("renders %s and the output is not valid YAML: %w", target, err)
		}
	}
	return nil
}

// recordedTarget: what this template says it renders, or "" when it says nothing.
func recordedTarget(root, name string) string {
	raw, err := os.ReadFile(filepath.Join(root, name, "meta.json"))
	if err != nil {
		return ""
	}
	var meta struct {
		TargetPath string `json:"target_path"`
	}
	if json.Unmarshal(raw, &meta) != nil {
		return ""
	}
	return meta.TargetPath
}

// TestConfigTemplatesRenderWithSample renders every shipped Class-B template
// (configs/config_templates/<name>/template.j2) against its sample.json via the
// real gonja engine and asserts non-empty output. This guards against
// Django/pongo2-isms (colon filters, unsupported tests) the LLM bootstrap might
// emit — they fail under gonja and break here, not silently on a live host.
//
// A RATCHET, NOT A PASS/FAIL WALL. Measured on the generated library: 147 of 5474 templates cannot render
// their own sample — 55 do not parse, 89 die at render time (`isinstance is not callable`: the model wrote
// Python builtins into Jinja), 3 render empty. Failing the whole test on those made it useless as a guard,
// because a red test says nothing about the change in front of you.
//
// So the known-broken set is a RECORD (configs/template_render_broken.json), and this test asserts two
// things about it: nothing outside the record may fail, and nothing inside it may still be listed once it
// renders. The record also feeds the server's gate, so a template that provably cannot render is not
// offered as an editor at all — the same rule as everywhere else here: an editor that cannot be correct is
// not offered. Regenerate with TEMPLATE_RENDER_WRITE=1 go test -run TestConfigTemplatesRenderWithSample.
func TestConfigTemplatesRenderWithSample(t *testing.T) {
	root := filepath.Join("..", "..", "configs", "config_templates")
	recordPath := filepath.Join("..", "..", "configs", "template_render_broken.json")
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read %s: %v", root, err)
	}
	known := map[string]string{}
	if raw, err := os.ReadFile(recordPath); err == nil {
		if err := json.Unmarshal(raw, &known); err != nil {
			t.Fatalf("parse %s: %v", recordPath, err)
		}
	}
	dest := filepath.Join(t.TempDir(), "rendered.out")
	broken := map[string]string{}
	var regressed, fixed []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		err := renderTemplateWithSample(root, name, dest)
		_, listed := known[name]
		switch {
		case err != nil:
			// 400, not 200: the record is what a repair pass reads, and gonja puts the useful part LAST —
			// which filter is missing, which method was called on what. At 200 characters every message
			// ended mid-sentence and the classes were indistinguishable.
			reason := err.Error()
			if len(reason) > 400 {
				reason = reason[:400]
			}
			broken[name] = reason
			if !listed {
				regressed = append(regressed, name+": "+reason)
			}
		case listed:
			fixed = append(fixed, name)
		}
	}
	if os.Getenv("TEMPLATE_RENDER_WRITE") == "1" {
		out, _ := json.MarshalIndent(broken, "", " ")
		if err := os.WriteFile(recordPath, append(out, '\n'), 0o644); err != nil {
			t.Fatalf("write %s: %v", recordPath, err)
		}
		t.Logf("recorded %d templates that cannot render their own sample", len(broken))
		return
	}
	for _, r := range regressed {
		t.Errorf("template no longer renders and is not in the record: %s", r)
	}
	if len(fixed) > 0 {
		t.Errorf("%d recorded templates render fine now — drop them from %s: %v",
			len(fixed), filepath.Base(recordPath), fixed[:min(len(fixed), 10)])
	}
}

// WHY A BOOLEAN DEFAULT BELONGS IN THE CATALOG AS A WORD, not as a bool — the two halves of the reason,
// characterised here so a change in either is noticed.
//
// Half one: gonja renders a bool PYTHON-CASED, because Jinja2 does. `debug={{ debug }}` with false writes
// "False", which shell, INI and YAML all reject (or read as a non-empty string, i.e. always true). 13 381
// template fields in the catalog carry a JSON-boolean default, so this is not a corner.
func TestGonjaRendersBooleansPythonCased(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "app.conf")
	_, err := NewTemplateRender().Run(context.Background(), map[string]any{
		"template": "debug={{ debug }} verbose={{ verbose }} workers={{ workers }}",
		"dest":     dest,
		"values":   map[string]any{"debug": false, "verbose": true, "workers": float64(4)},
	}, false)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	got, _ := os.ReadFile(dest)
	// The number IS normalised (that is what normalizeValues does); the booleans deliberately are not.
	if string(got) != "debug=False verbose=True workers=4" {
		t.Errorf("rendered %q — if this changed, revisit tools/bool_vocabulary.py and this comment", got)
	}
}

// Half two: WHY the fix cannot live here. Coercing the bool to the string "false" on the way in was tried,
// and it broke boolean semantics — a non-empty string is truthy, so `false | yes_no` rendered "yes" and every
// `{% if flag %}` took the wrong branch. Silently inverting a template's logic is far worse than a
// capitalised literal, so this is the guard against trying it again.
func TestBooleanSemanticsSurviveTheValuePipeline(t *testing.T) {
	dir := t.TempDir()
	for _, c := range []struct{ tmpl, want string }{
		{"{{ flag | ternary('on','off') }}", "off"},
		{"{{ flag | yes_no }}", "no"},
		{"{% if flag %}yes{% else %}no{% endif %}", "no"},
	} {
		dest := filepath.Join(dir, strings.ReplaceAll(c.tmpl, "/", "_"))
		_, err := NewTemplateRender().Run(context.Background(), map[string]any{
			"template": c.tmpl, "dest": dest, "values": map[string]any{"flag": false},
		}, false)
		if err != nil {
			t.Fatalf("%s: %v", c.tmpl, err)
		}
		got, _ := os.ReadFile(dest)
		if string(got) != c.want {
			t.Errorf("%s with false rendered %q, want %q — a bool must stay a bool through the pipeline",
				c.tmpl, got, c.want)
		}
	}
}

// And the shape the catalog now produces for a yes/no file: the value IS the word, so it renders as the word.
func TestAWordValuedFieldRendersTheWord(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "sarg.conf")
	_, err := NewTemplateRender().Run(context.Background(), map[string]any{
		"template": "overwrite_report {{ overwrite_report }}",
		"dest":     dest,
		"values":   map[string]any{"overwrite_report": "yes"},
	}, false)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	got, _ := os.ReadFile(dest)
	if string(got) != "overwrite_report yes" {
		t.Errorf("rendered %q", got)
	}
}
