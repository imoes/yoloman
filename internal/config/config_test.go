package config

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTemp(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("writing temp config: %v", err)
	}
	return path
}

func TestLoad_Defaults(t *testing.T) {
	path := writeTemp(t, `
listen: "0.0.0.0:8010"
token: "abc123"
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Write != false {
		t.Errorf("expected write=false by default, got %v", cfg.Write)
	}
	if cfg.DB.Driver != "sqlite" {
		t.Errorf("expected default db.driver=sqlite, got %q", cfg.DB.Driver)
	}
	if cfg.PAM.Service != "agentic-mcp" {
		t.Errorf("expected default pam.service=agentic-mcp, got %q", cfg.PAM.Service)
	}
	if cfg.Listen != "0.0.0.0:8010" {
		t.Errorf("expected overridden listen, got %q", cfg.Listen)
	}
}

func TestLoad_WriteTrueOverride(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
write: true
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !cfg.Write {
		t.Errorf("expected write=true to be honored")
	}
}

func TestLoad_MissingFile(t *testing.T) {
	_, err := Load(filepath.Join(t.TempDir(), "does-not-exist.yaml"))
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestValidate_RejectsUnknownDBDriver(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
db:
  driver: "postgres"
  path: "unused"
`)
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected error for unsupported db.driver in v1")
	}
}

func TestValidate_RejectsEmptyListen(t *testing.T) {
	path := writeTemp(t, `
listen: ""
`)
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected error for empty listen")
	}
}

func TestValidate_TLSRequiresCertAndKey(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
tls:
  enabled: true
`)
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected error when tls.enabled but cert/key missing")
	}
}
