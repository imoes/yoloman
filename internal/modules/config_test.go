package modules

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runConfig(t *testing.T, params map[string]any, dryRun bool) Result {
	t.Helper()
	res, err := NewConfig().Run(context.Background(), params, dryRun)
	if err != nil {
		t.Fatalf("config.Run: %v", err)
	}
	return res
}

func TestConfigKeyValueReadAndMerge(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "sshd_config")
	os.WriteFile(p, []byte("# ssh daemon\nPort 22\nPermitRootLogin yes\n\n# auth\nPasswordAuthentication yes\n"), 0o644)

	// READ: no values → parse the file.
	r := runConfig(t, map[string]any{"path": p, "format": "keyvalue"}, false)
	cfg := r.Data.(map[string]any)["config"].(map[string]any)
	if cfg["Port"] != "22" || cfg["PermitRootLogin"] != "yes" {
		t.Fatalf("parsed = %v", cfg)
	}

	// WRITE (merge): flip two keys, add one; comments + order preserved.
	r = runConfig(t, map[string]any{"path": p, "format": "keyvalue",
		"values": map[string]any{"PermitRootLogin": "no", "X11Forwarding": "no"}}, false)
	if !r.Changed {
		t.Fatal("expected changed")
	}
	out, _ := os.ReadFile(p)
	s := string(out)
	if !strings.Contains(s, "# ssh daemon") || !strings.Contains(s, "PermitRootLogin no") {
		t.Fatalf("merge lost comment or did not update in place:\n%s", s)
	}
	if strings.Contains(s, "PermitRootLogin yes") {
		t.Fatalf("old value still present:\n%s", s)
	}
	if !strings.Contains(s, "X11Forwarding no") {
		t.Fatalf("new key not appended:\n%s", s)
	}
	// idempotent: same values again → no change.
	r = runConfig(t, map[string]any{"path": p, "format": "keyvalue",
		"values": map[string]any{"PermitRootLogin": "no", "X11Forwarding": "no"}}, false)
	if r.Changed {
		t.Fatal("second apply should be idempotent")
	}
}

func TestConfigYamlDeepMerge(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "daemon.json")
	os.WriteFile(p, []byte("log-driver: json-file\nlog-opts:\n  max-size: 10m\n"), 0o644)
	r := runConfig(t, map[string]any{"path": p, "format": "yaml",
		"values": map[string]any{"log-opts": map[string]any{"max-file": "3"}, "live-restore": true}}, false)
	if !r.Changed {
		t.Fatal("expected changed")
	}
	cfg := r.Data.(map[string]any)["config"].(map[string]any)
	lo := cfg["log-opts"].(map[string]any)
	if lo["max-size"] != "10m" || lo["max-file"] != "3" {
		t.Fatalf("deep-merge lost/failed: %v", lo)
	}
	if cfg["live-restore"] != true {
		t.Fatalf("new key missing: %v", cfg)
	}
}

func TestConfigDryRunDoesNotWrite(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "app.conf")
	os.WriteFile(p, []byte("a=1\n"), 0o644)
	r := runConfig(t, map[string]any{"path": p, "format": "keyvalue", "separator": "=",
		"values": map[string]any{"a": "2"}}, true)
	if !r.Changed {
		t.Fatal("dry-run should still report changed")
	}
	out, _ := os.ReadFile(p)
	if string(out) != "a=1\n" {
		t.Fatalf("dry-run must not write, got: %q", out)
	}
}

func TestConfigIniReadAndMerge(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "app.ini")
	os.WriteFile(p, []byte("# global\ndebug = no\n\n[server]\nhost = 0.0.0.0\nport = 8080\n\n[auth]\nrealm = EXAMPLE\n"), 0o644)

	// READ → nested {section: {k:v}} with "" for the pre-section keys.
	r := runConfig(t, map[string]any{"path": p, "format": "ini"}, false)
	cfg := r.Data.(map[string]any)["config"].(map[string]any)
	if cfg[""].(map[string]any)["debug"] != "no" {
		t.Fatalf("global section parse: %v", cfg[""])
	}
	if cfg["server"].(map[string]any)["port"] != "8080" {
		t.Fatalf("server section parse: %v", cfg["server"])
	}

	// MERGE: change port, add a key to [auth], add a new [tls] section.
	r = runConfig(t, map[string]any{"path": p, "format": "ini", "values": map[string]any{
		"server": map[string]any{"port": "9090"},
		"auth":   map[string]any{"timeout": "30"},
		"tls":    map[string]any{"enabled": "true"},
	}}, false)
	if !r.Changed {
		t.Fatal("expected changed")
	}
	s, _ := os.ReadFile(p)
	out := string(s)
	for _, want := range []string{"# global", "port = 9090", "timeout = 30", "[tls]", "enabled = true"} {
		if !strings.Contains(out, want) {
			t.Fatalf("ini merge missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "port = 8080") {
		t.Fatalf("old port still present:\n%s", out)
	}
	// idempotent
	r = runConfig(t, map[string]any{"path": p, "format": "ini", "values": map[string]any{"server": map[string]any{"port": "9090"}}}, false)
	if r.Changed {
		t.Fatal("second apply should be idempotent")
	}
}

func TestConfigXmlRoundTrip(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "domain.xml")
	os.WriteFile(p, []byte("<domain type=\"kvm\"><name>web1</name><vcpu>2</vcpu></domain>"), 0o644)
	r := runConfig(t, map[string]any{"path": p, "format": "xml"}, false)
	cfg := r.Data.(map[string]any)["config"].(map[string]any)
	dom, ok := cfg["domain"].(map[string]any)
	if !ok || dom["name"] != "web1" {
		t.Fatalf("xml parse: %v", cfg)
	}
	// merge: bump vcpu
	r = runConfig(t, map[string]any{"path": p, "format": "xml", "values": map[string]any{"domain": map[string]any{"vcpu": "4"}}}, false)
	if !r.Changed {
		t.Fatal("expected changed")
	}
	out, _ := os.ReadFile(p)
	if !strings.Contains(string(out), "<vcpu>4</vcpu>") || !strings.Contains(string(out), "<name>web1</name>") {
		t.Fatalf("xml merge: %s", out)
	}
}
