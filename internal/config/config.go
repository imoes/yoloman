// Package config loads and validates the agentic-mcpd configuration file.
package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Config is the top-level daemon configuration (config.yaml).
type Config struct {
	Listen string `yaml:"listen"`
	Token  string `yaml:"token"`
	Write  bool   `yaml:"write"`
	TLS    TLS    `yaml:"tls"`
	EBPF   EBPF   `yaml:"ebpf"`
	DB     DB     `yaml:"db"`
	PAM    PAM    `yaml:"pam"`
	UI     UI     `yaml:"ui"`
	ToolsDir     string `yaml:"tools_dir"`
	CommandsFile string `yaml:"commands_file"`
}

type TLS struct {
	Enabled  bool   `yaml:"enabled"`
	CertFile string `yaml:"cert_file"`
	KeyFile  string `yaml:"key_file"`
}

type EBPF struct {
	Enabled bool `yaml:"enabled"`
}

type DB struct {
	Driver string `yaml:"driver"` // sqlite (v1)
	Path   string `yaml:"path"`
}

type PAM struct {
	Enabled bool   `yaml:"enabled"`
	Service string `yaml:"service"`
}

type UI struct {
	Enabled bool `yaml:"enabled"`
}

// Default returns a Config with safe, conservative defaults (write disabled).
func Default() Config {
	return Config{
		Listen: "127.0.0.1:8010",
		Write:  false,
		EBPF:   EBPF{Enabled: true},
		DB:     DB{Driver: "sqlite", Path: "/var/lib/agentic-mcp/agentic-mcp.db"},
		PAM:    PAM{Enabled: true, Service: "agentic-mcp"},
		UI:     UI{Enabled: true},
		ToolsDir:     "/etc/agentic-mcp/tools.d",
		CommandsFile: "/etc/agentic-mcp/commands.yaml",
	}
}

// Load reads and parses the YAML config file at path, applying defaults for
// any field left unset. It returns an error if the file cannot be read/parsed
// or fails Validate.
func Load(path string) (Config, error) {
	cfg := Default()

	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("reading config %q: %w", path, err)
	}
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parsing config %q: %w", path, err)
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, fmt.Errorf("invalid config %q: %w", path, err)
	}
	return cfg, nil
}

// Validate checks the config for internally consistent, safe values.
func (c Config) Validate() error {
	if c.Listen == "" {
		return fmt.Errorf("listen must not be empty")
	}
	if c.DB.Driver != "sqlite" {
		return fmt.Errorf("unsupported db.driver %q (v1 supports only sqlite)", c.DB.Driver)
	}
	if c.DB.Path == "" {
		return fmt.Errorf("db.path must not be empty")
	}
	if c.TLS.Enabled && (c.TLS.CertFile == "" || c.TLS.KeyFile == "") {
		return fmt.Errorf("tls.enabled requires tls.cert_file and tls.key_file")
	}
	return nil
}
