// Package config loads and validates the agentic-mcpd configuration file.
package config

import (
	"fmt"
	"os"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/mutkluge/agentic-mcp/internal/authz"
)

// Config is the top-level daemon configuration (config.yaml).
type Config struct {
	Listen string `yaml:"listen"`
	Token  string `yaml:"token"`
	// Tokens holds additional named bearer tokens beyond the single
	// legacy Token above, each scoped independently via ACL rules keyed
	// to its name (PrincipalToken rows matching that name — see
	// internal/authz.TokenEntry/ResolveBearerToken and docs/plan.md's
	// per-token RBAC design). Token remains the default, backward-
	// compatible single-token identity ("service-token"); entries here
	// each get their own named Identity, so different machine callers
	// (e.g. a CI pipeline vs. the future Bossman) can be granted
	// different tool scopes instead of every bearer token resolving to
	// the same fixed principal.
	Tokens []NamedToken `yaml:"tokens"`
	Write  bool         `yaml:"write"`
	// AllowSelfUpdate gates the agent self-update endpoint
	// (POST /api/v1/agent/self-update), which upgrades the agent from a
	// Bossman-pushed .deb even when Write is false. Default true (see
	// Default()); set to false to forbid remote upgrades of this agent.
	AllowSelfUpdate bool      `yaml:"allow_self_update"`
	TLS             TLS       `yaml:"tls"`
	EBPF            EBPF      `yaml:"ebpf"`
	DB              DB        `yaml:"db"`
	PAM             PAM       `yaml:"pam"`
	UI              UI        `yaml:"ui"`
	Console         Console   `yaml:"console"`
	Piggyback       Piggyback `yaml:"piggyback"`
	ToolsDir        string    `yaml:"tools_dir"`
	// ModulesDir holds translated Starlark collection modules
	// (<collection>/<name>.star + .nt/.yaml sidecar), loaded and registered
	// as executable tools at startup (Block G3). Optional dir like tools_dir.
	ModulesDir   string `yaml:"modules_dir"`
	CommandsFile string `yaml:"commands_file"`
	ACLPath      string `yaml:"acl_path"`

	// UploadsDir is the fixed staging directory the upload_file MCP tool
	// and the PUT /api/v1/upload REST endpoint write into — never an
	// arbitrary caller-supplied path (see docs/plan.md's "File upload
	// (staging)"). Final placement at a real destination path, with the
	// right owner/group/mode, is the copy module's job.
	UploadsDir string `yaml:"uploads_dir"`
	// MaxUploadSize bounds both upload paths (bytes). The default is large
	// enough for a kernel package (up to ~274 MiB observed in practice).
	MaxUploadSize int64 `yaml:"max_upload_size"`

	// Mode selects this agent's role relative to a central Fleet Commander
	// (see docs/plan.md's "Three operating modes"): "standalone" (default,
	// fully self-contained), "satellite" (documents intent — a Commander is
	// expected to pull this agent's data; no behavioral change), or "proxy"
	// (this agent additionally pulls from Proxy.Satellites and relays their
	// data alongside its own).
	Mode  string `yaml:"mode"`
	Proxy Proxy  `yaml:"proxy"`

	// Collect controls the periodic /proc sampler (internal/collect) that
	// writes CPU/memory/disk/uptime/network metrics into the local store
	// and derives built-in CPU/memory/disk/uptime checks from them — see
	// docs/plan.md's monitoring-cockpit ergänzung. Enabled by default:
	// without it, this agent writes no real metric at all (only the
	// one-shot startup marker), leaving any fleet cockpit polling it with
	// nothing to show.
	Collect Collect `yaml:"collect"`
	// Checks lists external Nagios/CheckMK-plugin-style commands
	// (internal/checks) to run on their own interval, alongside the
	// built-in checks Collect always derives from sampled metrics. Empty
	// by default — the built-ins already give every host meaningful
	// services with zero configuration.
	Checks []CheckSpec `yaml:"checks"`

	// L4 desired-state (docs/policy-orchestration-architecture.md §6):
	// there is deliberately NO config here for talking to Bossman. The
	// controller PUSHES compiled config to the agent's
	// POST /api/v1/config/apply over the existing server→agent mTLS
	// channel; the agent never dials out (single firewall rule, Bossman →
	// agent). The applied state is persisted next to the DB file.
}

// Collect configures the periodic OS-metric sampler.
type Collect struct {
	Enabled  bool     `yaml:"enabled"`
	Interval Duration `yaml:"interval"`
	// Docker (Block J3): sample per-container CPU/RAM/running from the Docker
	// Engine API on the same interval, emitted as docker_container_* metrics.
	// Enabled by default but degrades silently when the socket is absent
	// (Docker not installed), so it's safe to leave on everywhere.
	Docker       bool   `yaml:"docker"`
	DockerSocket string `yaml:"docker_socket"`
	// Services (Block J3b): sample per-systemd-service CPU/memory/IO from the
	// cgroup filesystem, emitted as service_* metrics labeled by unit — the
	// legacy-host counterpart to Docker container metrics. Default true;
	// no-op on hosts without a system.slice cgroup.
	Services   bool   `yaml:"services"`
	CgroupRoot string `yaml:"cgroup_root"`
}

// CheckSpec is one externally configured check: an argv to run via
// internal/checks.RunDefault on its own ticker, following the Nagios
// Plugin API contract (exit code + "message | perfdata" stdout).
type CheckSpec struct {
	Name     string   `yaml:"name"`
	Command  []string `yaml:"command"`
	Interval Duration `yaml:"interval"`
	Timeout  Duration `yaml:"timeout"`
}

// NamedToken is one additional bearer token, scoped to its own ACL
// identity (Kind: token, Name: Name) — see Config.Tokens.
type NamedToken struct {
	Name  string `yaml:"name"`
	Token string `yaml:"token"`
}

// TokenEntries converts c.Tokens to the []authz.TokenEntry shape
// authz.ResolveBearerToken expects, so callers (the MCP and REST auth
// middleware) don't need to know about config.NamedToken's YAML shape.
func (c Config) TokenEntries() []authz.TokenEntry {
	if len(c.Tokens) == 0 {
		return nil
	}
	entries := make([]authz.TokenEntry, len(c.Tokens))
	for i, t := range c.Tokens {
		entries[i] = authz.TokenEntry{Name: t.Name, Token: t.Token}
	}
	return entries
}

// Proxy configures proxy-mode satellite polling: a list of satellites this
// agent pulls performance data from over TLS, for fleets where a central
// Fleet Commander can't reach every satellite directly. ClientCertFile/
// ClientKeyFile are this proxy's own client identity — the certificate it
// presents to every satellite it polls, verified by each satellite against
// its own tls.trusted_client_keys (see TLS below). This is the same
// mechanism a Fleet Commander would use to authenticate directly against
// any node agent's REST/MCP API.
type Proxy struct {
	ClientCertFile string      `yaml:"client_cert_file"`
	ClientKeyFile  string      `yaml:"client_key_file"`
	Satellites     []Satellite `yaml:"satellites"`

	// EnrollSecret, when set, activates this proxy's own server-side
	// POST /api/v1/enroll endpoint ("Selecta" acting as an enrollment
	// authority for its satellites — see docs/plan.md) — a standalone
	// agent runs `agentic-mcpd register --enroll-url https://<this
	// proxy>` to add itself as a satellite. The handed-out public key is
	// this proxy's own ClientCertFile's public key (the identity it
	// already uses to poll satellites), so a newly enrolled satellite
	// pins exactly the certificate that will actually connect to it —
	// no separate enrollment keypair needed. Left empty (the default),
	// the endpoint is not registered at all, the same registration-gate
	// pattern used elsewhere in this project (e.g. the write gate).
	EnrollSecret string `yaml:"enroll_secret"`

	// SatellitesPath is where dynamically enrolled/removed satellites
	// (via the enrollment endpoint and DELETE /api/v1/proxy/satellites)
	// are persisted, layered on top of the statically configured
	// Satellites list above — see internal/fleet.SatelliteRegistry.
	SatellitesPath string `yaml:"satellites_path"`
}

// Satellite is one proxy-mode upstream: a satellite agent reachable over
// TLS at Address. The satellite's own bearer Token authenticates the REST
// call in addition to the proxy's client certificate (Proxy.ClientCertFile/
// ClientKeyFile) presented at the TLS layer — defense in depth, not either/or.
type Satellite struct {
	Name         string   `yaml:"name"`
	Address      string   `yaml:"address"` // host:port of the satellite's REST API, e.g. "sat1.example.com:8010"
	Token        string   `yaml:"token"`
	PollInterval Duration `yaml:"poll_interval"`
}

// TLS configures this agent's own HTTPS listener.
type TLS struct {
	Enabled  bool   `yaml:"enabled"`
	CertFile string `yaml:"cert_file"`
	KeyFile  string `yaml:"key_file"`

	// TrustedClientKeys, when non-empty, requires every /api/v1/ and /mcp
	// request to present a TLS client certificate whose public key matches
	// one of these entries before the bearer-token check even runs — the
	// SSH authorized_keys model, but for machine callers (a Fleet Commander
	// or a proxy) connecting to this agent. Checked in addition to, not
	// instead of, the existing bearer token. The web UI (/ui/) and
	// /healthz are unaffected — this only gates the machine-facing API.
	TrustedClientKeys []TrustedClientKey `yaml:"trusted_client_keys"`
}

// TrustedClientKey is one authorized machine caller: a name (for logging)
// and the PEM-encoded PKIX public key to pin, distributed out of band
// (e.g. via `openssl x509 -pubkey -noout` run against that caller's own
// client certificate).
type TrustedClientKey struct {
	Name          string `yaml:"name"`
	PublicKeyPath string `yaml:"public_key_path"`
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

// Console configures the interactive web shell (GET /api/v1/console). Command
// is the program spawned in the PTY; empty uses console.DefaultCommand
// (/bin/login), so the operator authenticates in the terminal via PAM.
type Console struct {
	Enabled bool     `yaml:"enabled"`
	Command []string `yaml:"command"`
}

// Piggyback configures reporting guests (containers/VMs) as their own hosts via
// hosts/overview (CheckMK-style piggyback). Docker is auto-detected: with
// docker enabled but no daemon present, it's a silent no-op.
type Piggyback struct {
	Docker       bool   `yaml:"docker"`        // report Docker containers as hosts
	DockerSocket string `yaml:"docker_socket"` // default /var/run/docker.sock
}

// Default returns a Config with safe, conservative defaults (write disabled).
func Default() Config {
	return Config{
		Listen:          "127.0.0.1:8010",
		Write:           false,
		AllowSelfUpdate: true,
		EBPF:            EBPF{Enabled: true},
		DB: DB{
			Driver: "sqlite",
			Path:   "/var/lib/agentic-mcp/agentic-mcp.db",
			Retention: Retention{
				Raw:      Duration(24 * time.Hour),
				Hourly:   Duration(30 * 24 * time.Hour),
				Interval: Duration(time.Hour),
			},
		},
		PAM:           PAM{Enabled: true, Service: "agentic-mcp", SessionTTL: Duration(12 * time.Hour)},
		UI:            UI{Enabled: true},
		Console:       Console{Enabled: true},
		Piggyback:     Piggyback{Docker: true},
		ToolsDir:      "/etc/agentic-mcp/tools.d",
		ModulesDir:    "/var/lib/agentic-mcp/modules.d",
		CommandsFile:  "/etc/agentic-mcp/commands.yaml",
		ACLPath:       "/var/lib/agentic-mcp/acl.db",
		UploadsDir:    "/var/lib/agentic-mcp/uploads",
		MaxUploadSize: 512 * 1024 * 1024,
		Mode:          "standalone",
		Proxy:         Proxy{SatellitesPath: "/var/lib/agentic-mcp/satellites.db"},
		Collect:       Collect{Enabled: true, Interval: Duration(30 * time.Second), Docker: true, DockerSocket: "/var/run/docker.sock", Services: true},
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
	if c.UploadsDir == "" {
		return fmt.Errorf("uploads_dir must not be empty")
	}
	if c.MaxUploadSize <= 0 {
		return fmt.Errorf("max_upload_size must be > 0")
	}
	seenTokenNames := make(map[string]bool, len(c.Tokens))
	for i, t := range c.Tokens {
		if t.Name == "" {
			return fmt.Errorf("tokens[%d]: name must not be empty", i)
		}
		if t.Name == authz.TokenPrincipalName {
			return fmt.Errorf("tokens[%d]: name %q is reserved for the legacy single token", i, authz.TokenPrincipalName)
		}
		if seenTokenNames[t.Name] {
			return fmt.Errorf("tokens: duplicate name %q", t.Name)
		}
		seenTokenNames[t.Name] = true
		if t.Token == "" {
			return fmt.Errorf("tokens[%s]: token must not be empty", t.Name)
		}
	}
	if c.TLS.Enabled && (c.TLS.CertFile == "" || c.TLS.KeyFile == "") {
		return fmt.Errorf("tls.enabled requires tls.cert_file and tls.key_file")
	}
	if len(c.TLS.TrustedClientKeys) > 0 && !c.TLS.Enabled {
		return fmt.Errorf("tls.trusted_client_keys requires tls.enabled")
	}
	seenKeyNames := make(map[string]bool, len(c.TLS.TrustedClientKeys))
	for i, k := range c.TLS.TrustedClientKeys {
		if k.Name == "" {
			return fmt.Errorf("tls.trusted_client_keys[%d]: name must not be empty", i)
		}
		if seenKeyNames[k.Name] {
			return fmt.Errorf("tls.trusted_client_keys: duplicate name %q", k.Name)
		}
		seenKeyNames[k.Name] = true
		if k.PublicKeyPath == "" {
			return fmt.Errorf("tls.trusted_client_keys[%s]: public_key_path must not be empty", k.Name)
		}
	}
	switch c.Mode {
	case "", "standalone", "satellite":
	case "proxy":
		// No longer requires at least one statically configured satellite:
		// since satellites can now be enrolled dynamically at runtime (see
		// internal/fleet.SatelliteRegistry and the enrollment endpoint), a
		// proxy legitimately starts with zero and grows its list later.
		if c.Proxy.ClientCertFile == "" || c.Proxy.ClientKeyFile == "" {
			return fmt.Errorf("mode: proxy requires proxy.client_cert_file and proxy.client_key_file (this agent's own client identity)")
		}
		if c.Proxy.SatellitesPath == "" {
			return fmt.Errorf("mode: proxy requires proxy.satellites_path")
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
		}
	default:
		return fmt.Errorf("unsupported mode %q (must be standalone, satellite, or proxy)", c.Mode)
	}

	seenCheckNames := make(map[string]bool, len(c.Checks))
	for i, chk := range c.Checks {
		if chk.Name == "" {
			return fmt.Errorf("checks[%d]: name must not be empty", i)
		}
		if seenCheckNames[chk.Name] {
			return fmt.Errorf("checks: duplicate name %q", chk.Name)
		}
		seenCheckNames[chk.Name] = true
		if len(chk.Command) == 0 {
			return fmt.Errorf("checks[%s]: command must not be empty", chk.Name)
		}
	}
	return nil
}
