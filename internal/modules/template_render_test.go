package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
