// Package config loads and validates the agentic-mcpd configuration file.
package config

import (
	"fmt"
	"os"
	"time"

	"gopkg.in/yaml.v3"
)

// Config is the top-level daemon configuration (config.yaml).
type Config struct {
	Listen       string `yaml:"listen"`
	Token        string `yaml:"token"`
	Write        bool   `yaml:"write"`
	TLS          TLS    `yaml:"tls"`
	EBPF         EBPF   `yaml:"ebpf"`
	DB           DB     `yaml:"db"`
	PAM          PAM    `yaml:"pam"`
	UI           UI     `yaml:"ui"`
	ToolsDir     string `yaml:"tools_dir"`
	CommandsFile string `yaml:"commands_file"`
	ACLPath      string `yaml:"acl_path"`

	// Mode selects this agent's role relative to a central Fleet Commander
	// (see docs/plan.md's "Three operating modes"): "standalone" (default,
	// fully self-contained), "satellite" (documents intent — a Commander is
	// expected to pull this agent's data; no behavioral change), or "proxy"
	// (this agent additionally pulls from Proxy.Satellites and relays their
	// data alongside its own).
	Mode  string `yaml:"mode"`
	Proxy Proxy  `yaml:"proxy"`
}

// Proxy configures proxy-mode satellite polling: a list of satellites this
// agent pulls performance data from over TLS, for fleets where a central
// Fleet Commander can't reach every satellite directly.
type Proxy struct {
	Satellites []Satellite `yaml:"satellites"`
}

// Satellite is one proxy-mode upstream: a satellite agent reachable over
// TLS, authenticated the way SSH authenticates a host — not via a CA, but
// by the proxy pinning the satellite's exact public key up front (its
// PublicKeyPath, distributed out of band, analogous to an SSH
// known_hosts entry). The satellite proves possession of the matching
// private key during the TLS handshake (its own tls.cert_file/key_file,
// see TLS above); the proxy verifies the presented certificate's public
// key against the pin instead of trusting a certificate authority. The
// satellite's own bearer Token authenticates the REST call underneath,
// same as any other REST client.
type Satellite struct {
	Name          string   `yaml:"name"`
	Address       string   `yaml:"address"`         // host:port of the satellite's REST API, e.g. "sat1.example.com:8010"
	PublicKeyPath string   `yaml:"public_key_path"` // PEM-encoded PKIX public key to pin (distributed out of band)
	Token         string   `yaml:"token"`
	PollInterval  Duration `yaml:"poll_interval"`
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
	Driver    string    `yaml:"driver"` // sqlite (v1)
	Path      string    `yaml:"path"`
	Retention Retention `yaml:"retention"`
}

// Retention controls the store's downsampling job: how long raw points
// live before being averaged into hourly points, how long hourly points
// live before being averaged into daily points, and how often that job
// runs.
type Retention struct {
	Raw      Duration `yaml:"raw"`
	Hourly   Duration `yaml:"hourly"`
	Interval Duration `yaml:"interval"`
}

// Duration wraps time.Duration so it can be written in config.yaml as a
// plain Go duration string (e.g. "24h", "720h"), which time.Duration alone
// cannot unmarshal from YAML.
type Duration time.Duration

func (d Duration) Duration() time.Duration { return time.Duration(d) }

func (d *Duration) UnmarshalYAML(value *yaml.Node) error {
	var s string
	if err := value.Decode(&s); err != nil {
		return err
	}
	parsed, err := time.ParseDuration(s)
	if err != nil {
		return fmt.Errorf("invalid duration %q: %w", s, err)
	}
	*d = Duration(parsed)
	return nil
}

type PAM struct {
	Enabled    bool     `yaml:"enabled"`
	Service    string   `yaml:"service"`
	SessionTTL Duration `yaml:"session_ttl"`
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
		DB: DB{
			Driver: "sqlite",
			Path:   "/var/lib/agentic-mcp/agentic-mcp.db",
			Retention: Retention{
				Raw:      Duration(24 * time.Hour),
				Hourly:   Duration(30 * 24 * time.Hour),
				Interval: Duration(time.Hour),
			},
		},
		PAM:          PAM{Enabled: true, Service: "agentic-mcp", SessionTTL: Duration(12 * time.Hour)},
		UI:           UI{Enabled: true},
		ToolsDir:     "/etc/agentic-mcp/tools.d",
		CommandsFile: "/etc/agentic-mcp/commands.yaml",
		ACLPath:      "/var/lib/agentic-mcp/acl.db",
		Mode:         "standalone",
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
	switch c.Mode {
	case "", "standalone", "satellite":
	case "proxy":
		if len(c.Proxy.Satellites) == 0 {
			return fmt.Errorf("mode: proxy requires at least one entry under proxy.satellites")
		}
		seen := make(map[string]bool, len(c.Proxy.Satellites))
		for i, sat := range c.Proxy.Satellites {
			if sat.Name == "" {
				return fmt.Errorf("proxy.satellites[%d]: name must not be empty", i)
			}
			if seen[sat.Name] {
				return fmt.Errorf("proxy.satellites: duplicate name %q", sat.Name)
			}
			seen[sat.Name] = true
			if sat.Address == "" {
				return fmt.Errorf("proxy.satellites[%s]: address must not be empty", sat.Name)
			}
			if sat.PublicKeyPath == "" {
				return fmt.Errorf("proxy.satellites[%s]: public_key_path must not be empty", sat.Name)
			}
		}
	default:
		return fmt.Errorf("unsupported mode %q (must be standalone, satellite, or proxy)", c.Mode)
	}
	return nil
}
