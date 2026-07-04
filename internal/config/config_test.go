package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
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
	if cfg.DB.Retention.Raw.Duration() != 24*time.Hour {
		t.Errorf("expected default raw retention=24h, got %v", cfg.DB.Retention.Raw.Duration())
	}
	if cfg.DB.Retention.Hourly.Duration() != 30*24*time.Hour {
		t.Errorf("expected default hourly retention=720h, got %v", cfg.DB.Retention.Hourly.Duration())
	}
}

func TestLoad_RetentionOverride(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
db:
  driver: sqlite
  path: /tmp/x.db
  retention:
    raw: "12h"
    hourly: "168h"
    interval: "15m"
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.DB.Retention.Raw.Duration() != 12*time.Hour {
		t.Errorf("raw = %v, want 12h", cfg.DB.Retention.Raw.Duration())
	}
	if cfg.DB.Retention.Hourly.Duration() != 168*time.Hour {
		t.Errorf("hourly = %v, want 168h", cfg.DB.Retention.Hourly.Duration())
	}
	if cfg.DB.Retention.Interval.Duration() != 15*time.Minute {
		t.Errorf("interval = %v, want 15m", cfg.DB.Retention.Interval.Duration())
	}
}

func TestLoad_RetentionInvalidDuration(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
db:
  driver: sqlite
  path: /tmp/x.db
  retention:
    raw: "not-a-duration"
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for invalid duration string")
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

func TestLoad_ModeDefaultsToStandalone(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Mode != "standalone" {
		t.Errorf("expected default mode=standalone, got %q", cfg.Mode)
	}
}

func TestValidate_RejectsUnknownMode(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "bogus"
`)
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected error for unsupported mode")
	}
}

func TestValidate_ProxyModeWithNoStaticSatellitesIsValid(t *testing.T) {
	// Satellites can now be enrolled dynamically at runtime (see
	// internal/fleet.SatelliteRegistry) — a proxy legitimately starts
	// with zero statically configured satellites and grows its list
	// later, so this must NOT be a validation error (a real behavior
	// change from before dynamic enrollment existed).
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "proxy"
proxy:
  client_cert_file: /etc/agentic-mcp/proxy-cert.pem
  client_key_file: /etc/agentic-mcp/proxy-key.pem
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(cfg.Proxy.Satellites) != 0 {
		t.Errorf("expected no static satellites, got %+v", cfg.Proxy.Satellites)
	}
}

func TestValidate_ProxyModeMissingEverythingStillErrors(t *testing.T) {
	// With no proxy: block at all, client_cert_file/client_key_file are
	// still required, even though satellites alone are no longer
	// mandatory.
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "proxy"
`)
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected error for mode=proxy with no client identity configured")
	}
}

func TestValidate_ProxyModeDefaultsSatellitesPath(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "proxy"
proxy:
  client_cert_file: /etc/agentic-mcp/proxy-cert.pem
  client_key_file: /etc/agentic-mcp/proxy-key.pem
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Proxy.SatellitesPath == "" {
		t.Error("expected a default proxy.satellites_path")
	}
}

func TestValidate_ProxyModeRejectsEmptySatellitesPath(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "proxy"
proxy:
  client_cert_file: /etc/agentic-mcp/proxy-cert.pem
  client_key_file: /etc/agentic-mcp/proxy-key.pem
  satellites_path: ""
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for mode=proxy with an explicitly empty satellites_path")
	}
}

func TestValidate_ProxyModeEnrollSecretParsed(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "proxy"
proxy:
  client_cert_file: /etc/agentic-mcp/proxy-cert.pem
  client_key_file: /etc/agentic-mcp/proxy-key.pem
  enroll_secret: "shared-secret"
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Proxy.EnrollSecret != "shared-secret" {
		t.Errorf("EnrollSecret = %q, want shared-secret", cfg.Proxy.EnrollSecret)
	}
}

func TestValidate_ProxyModeWithSatellites(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "proxy"
proxy:
  client_cert_file: /etc/agentic-mcp/proxy-cert.pem
  client_key_file: /etc/agentic-mcp/proxy-key.pem
  satellites:
    - name: sat1
      address: "sat1.example.com:8010"
      token: "sat1-token"
      poll_interval: "30s"
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Proxy.ClientCertFile != "/etc/agentic-mcp/proxy-cert.pem" || cfg.Proxy.ClientKeyFile != "/etc/agentic-mcp/proxy-key.pem" {
		t.Errorf("unexpected proxy client identity: %+v", cfg.Proxy)
	}
	if len(cfg.Proxy.Satellites) != 1 {
		t.Fatalf("expected 1 satellite, got %d", len(cfg.Proxy.Satellites))
	}
	sat := cfg.Proxy.Satellites[0]
	if sat.Name != "sat1" || sat.Address != "sat1.example.com:8010" || sat.Token != "sat1-token" {
		t.Errorf("unexpected satellite config: %+v", sat)
	}
	if sat.PollInterval.Duration() != 30*time.Second {
		t.Errorf("poll_interval = %v, want 30s", sat.PollInterval.Duration())
	}
}

func TestValidate_ProxyModeRequiresClientIdentity(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "proxy"
proxy:
  satellites:
    - name: sat1
      address: "sat1.example.com:8010"
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for mode=proxy without proxy.client_cert_file/client_key_file")
	}
}

func TestValidate_ProxySatelliteMissingFields(t *testing.T) {
	base := `
listen: "127.0.0.1:8010"
mode: "proxy"
proxy:
  client_cert_file: /etc/agentic-mcp/proxy-cert.pem
  client_key_file: /etc/agentic-mcp/proxy-key.pem
  satellites:
    - name: sat1
      address: "sat1.example.com:8010"
`
	path := writeTemp(t, base)
	if _, err := Load(path); err != nil {
		t.Fatalf("expected valid config (token optional), got: %v", err)
	}

	missingAddress := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "proxy"
proxy:
  client_cert_file: /etc/agentic-mcp/proxy-cert.pem
  client_key_file: /etc/agentic-mcp/proxy-key.pem
  satellites:
    - name: sat1
`)
	if _, err := Load(missingAddress); err == nil {
		t.Fatal("expected error for missing address")
	}

	dup := writeTemp(t, `
listen: "127.0.0.1:8010"
mode: "proxy"
proxy:
  client_cert_file: /etc/agentic-mcp/proxy-cert.pem
  client_key_file: /etc/agentic-mcp/proxy-key.pem
  satellites:
    - name: sat1
      address: "sat1.example.com:8010"
    - name: sat1
      address: "sat2.example.com:8010"
`)
	if _, err := Load(dup); err == nil {
		t.Fatal("expected error for duplicate satellite name")
	}
}

func TestValidate_TrustedClientKeysRequiresTLS(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
tls:
  trusted_client_keys:
    - name: fleet-commander
      public_key_path: /etc/agentic-mcp/trusted/commander.pub.pem
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for tls.trusted_client_keys without tls.enabled")
	}
}

func TestValidate_TrustedClientKeysValid(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
tls:
  enabled: true
  cert_file: /etc/agentic-mcp/cert.pem
  key_file: /etc/agentic-mcp/key.pem
  trusted_client_keys:
    - name: fleet-commander
      public_key_path: /etc/agentic-mcp/trusted/commander.pub.pem
    - name: proxy-muc
      public_key_path: /etc/agentic-mcp/trusted/proxy-muc.pub.pem
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(cfg.TLS.TrustedClientKeys) != 2 {
		t.Fatalf("expected 2 trusted client keys, got %d", len(cfg.TLS.TrustedClientKeys))
	}
	if cfg.TLS.TrustedClientKeys[0].Name != "fleet-commander" || cfg.TLS.TrustedClientKeys[0].PublicKeyPath != "/etc/agentic-mcp/trusted/commander.pub.pem" {
		t.Errorf("unexpected first trusted key: %+v", cfg.TLS.TrustedClientKeys[0])
	}
}

func TestValidate_TrustedClientKeysDuplicateName(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
tls:
  enabled: true
  cert_file: /etc/agentic-mcp/cert.pem
  key_file: /etc/agentic-mcp/key.pem
  trusted_client_keys:
    - name: dup
      public_key_path: /etc/agentic-mcp/trusted/a.pub.pem
    - name: dup
      public_key_path: /etc/agentic-mcp/trusted/b.pub.pem
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for duplicate trusted_client_keys name")
	}
}

func TestValidate_TrustedClientKeysMissingPublicKeyPath(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
tls:
  enabled: true
  cert_file: /etc/agentic-mcp/cert.pem
  key_file: /etc/agentic-mcp/key.pem
  trusted_client_keys:
    - name: fleet-commander
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for missing public_key_path")
	}
}

func TestLoad_UploadDefaults(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.UploadsDir != "/var/lib/agentic-mcp/uploads" {
		t.Errorf("expected default uploads_dir, got %q", cfg.UploadsDir)
	}
	if cfg.MaxUploadSize != 512*1024*1024 {
		t.Errorf("expected default max_upload_size=512MiB, got %d", cfg.MaxUploadSize)
	}
}

func TestLoad_UploadOverride(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
uploads_dir: /tmp/custom-uploads
max_upload_size: 1024
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.UploadsDir != "/tmp/custom-uploads" {
		t.Errorf("uploads_dir = %q, want /tmp/custom-uploads", cfg.UploadsDir)
	}
	if cfg.MaxUploadSize != 1024 {
		t.Errorf("max_upload_size = %d, want 1024", cfg.MaxUploadSize)
	}
}

func TestValidate_RejectsEmptyUploadsDir(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
uploads_dir: ""
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for empty uploads_dir")
	}
}

func TestValidate_RejectsZeroMaxUploadSize(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
max_upload_size: 0
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for max_upload_size <= 0")
	}
}

func TestValidate_TokensValid(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
token: "legacy-secret"
tokens:
  - name: bossman
    token: bossman-secret
  - name: ci-pipeline
    token: ci-secret
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(cfg.Tokens) != 2 {
		t.Fatalf("expected 2 tokens, got %d", len(cfg.Tokens))
	}
	if cfg.Tokens[0].Name != "bossman" || cfg.Tokens[0].Token != "bossman-secret" {
		t.Errorf("unexpected first token: %+v", cfg.Tokens[0])
	}
}

func TestValidate_TokensDuplicateName(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
tokens:
  - name: dup
    token: a
  - name: dup
    token: b
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for duplicate tokens name")
	}
}

func TestValidate_TokensEmptyName(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
tokens:
  - name: ""
    token: a
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for empty token name")
	}
}

func TestValidate_TokensEmptyToken(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
tokens:
  - name: bossman
    token: ""
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for empty token value")
	}
}

func TestValidate_TokensRejectsReservedName(t *testing.T) {
	path := writeTemp(t, `
listen: "127.0.0.1:8010"
tokens:
  - name: service-token
    token: a
`)
	if _, err := Load(path); err == nil {
		t.Fatal("expected error for a token named after the reserved legacy identity")
	}
}

func TestTokenEntries_ConvertsToAuthzShape(t *testing.T) {
	cfg := Config{Tokens: []NamedToken{
		{Name: "bossman", Token: "bossman-secret"},
	}}
	entries := cfg.TokenEntries()
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if entries[0].Name != "bossman" || entries[0].Token != "bossman-secret" {
		t.Errorf("unexpected entry: %+v", entries[0])
	}
}

func TestTokenEntries_EmptyWhenNoTokens(t *testing.T) {
	cfg := Config{}
	if entries := cfg.TokenEntries(); entries != nil {
		t.Errorf("expected nil entries for no configured tokens, got %+v", entries)
	}
}
