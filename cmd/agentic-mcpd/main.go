// Command agentic-mcpd is the agentic-mcp node agent: it exposes Linux system
// state and management actions to AI clients via MCP (stdio or Streamable
// HTTP) and a plain REST API.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/audit"
	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/ebpf"
	"github.com/mutkluge/agentic-mcp/internal/fleet"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/server"
	"github.com/mutkluge/agentic-mcp/internal/store"
	"github.com/mutkluge/agentic-mcp/internal/tasks"
	"github.com/mutkluge/agentic-mcp/internal/tlsauth"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "agentic-mcpd:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) > 0 && args[0] == "register" {
		return runRegister(args[1:])
	}

	fs := flag.NewFlagSet("agentic-mcpd", flag.ContinueOnError)
	configPath := fs.String("config", "/etc/agentic-mcp/config.yaml", "path to config.yaml")
	stdio := fs.Bool("stdio", false, "serve MCP over stdio instead of Streamable HTTP")
	listen := fs.String("listen", "", "override the listen address from config")
	generateToken := fs.Bool("generate-token", false, "print a new cryptographically random bearer token and exit")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *generateToken {
		token, err := newBearerToken()
		if err != nil {
			return err
		}
		fmt.Println(token)
		return nil
	}

	cfg, err := loadConfigOrDefault(*configPath)
	if err != nil {
		return err
	}
	if *listen != "" {
		cfg.Listen = *listen
	}

	st, err := store.OpenSQLite(cfg.DB.Path)
	if err != nil {
		return fmt.Errorf("opening store: %w", err)
	}
	defer st.Close()

	if err := recordStartupMarker(st); err != nil {
		slog.Warn("failed to record startup marker", "error", err)
	}
	startRetentionLoop(cfg, st)

	proxyRegistry, satelliteManager := startProxyManager(cfg, st)
	if proxyRegistry != nil {
		defer proxyRegistry.Close()
	}
	if satelliteManager != nil {
		defer satelliteManager.Close()
	}
	proxyPublicKeyPEM := loadProxyPublicKeyOrWarn(cfg)

	comps, err := loadComponents(cfg)
	if err != nil {
		return err
	}

	acl, err := authz.OpenACL(cfg.ACLPath)
	if err != nil {
		return fmt.Errorf("opening ACL store: %w", err)
	}
	defer acl.Close()

	var pamAuth *authz.PAMAuthenticator
	var sessions *authz.SessionStore
	if cfg.PAM.Enabled {
		pamAuth = authz.NewPAMAuthenticator(cfg.PAM.Service)
		sessions = authz.NewSessionStore(cfg.PAM.SessionTTL.Duration())
	}

	collector := startEBPFCollector(cfg)
	if collector != nil {
		defer collector.Close()
		// st (store.Store) already satisfies ebpf.EdgeSink structurally —
		// no adapter needed. See docs/plan.md's Bossman "v3" Block A.
		collector.SetEdgeSink(st)
	}

	// Audit entries are written to stderr as JSON lines: under systemd
	// (the packaged deployment) each line lands in the journal
	// automatically and, being valid JSON, is directly consumable via
	// `journalctl -u agentic-mcp -o cat | jq` without a native journal
	// client dependency.
	al := audit.New(os.Stderr)

	mcpServer, err := newServer(cfg, st, comps, acl, collector, al)
	if err != nil {
		return err
	}

	if *stdio {
		return mcpServer.Run(context.Background(), &mcp.StdioTransport{})
	}

	restHandler := server.NewRESTHandler(server.RESTConfig{
		ProcRoot:          "/proc",
		ModReg:            comps.modReg,
		Tasks:             comps.taskList,
		Policy:            comps.policy,
		Store:             st,
		Write:             cfg.Write,
		Token:             cfg.Token,
		Tokens:            cfg.TokenEntries(),
		ACL:               acl,
		Sessions:          sessions,
		PAMAuth:           pamAuth,
		EBPF:              collector,
		Audit:             al,
		UploadsDir:        cfg.UploadsDir,
		MaxUploadSize:     cfg.MaxUploadSize,
		Mode:              cfg.Mode,
		ProxyEnrollSecret: cfg.Proxy.EnrollSecret,
		ProxyPublicKeyPEM: proxyPublicKeyPEM,
		SatelliteManager:  satelliteManager,
	})
	return serveHTTP(cfg, mcpServer, restHandler)
}

// startEBPFCollector loads and attaches the eBPF collector if enabled,
// running its ring-buffer consumer loop for the daemon's lifetime. Any
// failure (old kernel, no BTF/ring buffer support, missing CAP_BPF, ...) is
// logged as a warning and degrades gracefully to nil — every other
// capability keeps working without it, per docs/plan.md.
func startEBPFCollector(cfg config.Config) *ebpf.Collector {
	if !cfg.EBPF.Enabled {
		return nil
	}
	c, err := ebpf.New(0)
	if err != nil {
		slog.Warn("eBPF collector unavailable, continuing without it", "error", err)
		return nil
	}
	go c.Run(context.Background())
	slog.Info("eBPF collector attached (TCP connection tracking + exec events)")
	return c
}

// components bundles the shared building blocks (module registry, tools.d
// tasks, pipeline command policy) used by both the MCP and REST layers, so
// they're loaded once and stay identical across both access modes.
type components struct {
	modReg   *modules.Registry
	taskList []*tasks.Task
	policy   *pipeline.Policy
}

func loadComponents(cfg config.Config) (*components, error) {
	taskList, err := tasks.LoadDir(cfg.ToolsDir)
	if err != nil {
		return nil, fmt.Errorf("loading tools.d: %w", err)
	}
	return &components{
		modReg:   server.NewDefaultModuleRegistry(),
		taskList: taskList,
		policy:   loadCommandPolicyOrEmpty(cfg.CommandsFile),
	}, nil
}

// loadConfigOrDefault loads the config file if present, else falls back to
// Default() so the daemon can start with `--stdio` for local testing without
// requiring /etc/agentic-mcp/config.yaml to exist yet.
func loadConfigOrDefault(path string) (config.Config, error) {
	if _, err := os.Stat(path); err != nil {
		slog.Warn("config file not found, using defaults", "path", path)
		return config.Default(), nil
	}
	return config.Load(path)
}

// newServer builds the MCP server with all resources/tools registered.
func newServer(cfg config.Config, st store.Store, c *components, acl *authz.ACL, collector *ebpf.Collector, al *audit.Logger) (*mcp.Server, error) {
	s := mcp.NewServer(&mcp.Implementation{
		Name:    "agentic-mcp",
		Title:   "YOLO-MANager",
		Version: "0.1.0",
	}, nil)
	server.RegisterProc(s, "/proc")
	server.RegisterMetrics(s, st)
	server.RegisterMetricsDump(s, st)
	server.RegisterModules(s, c.modReg, cfg.Write, acl, al)
	server.RegisterRunPipeline(s, c.policy, cfg.Write, acl, al)
	server.RegisterUploadFile(s, cfg.UploadsDir, cfg.Write, acl, al)
	if err := server.RegisterTasks(s, c.taskList, c.modReg, c.policy, cfg.Write, acl, al); err != nil {
		return nil, err
	}
	if collector != nil {
		server.RegisterEBPF(s, collector)
	}
	return s, nil
}

// recordStartupMarker writes a single point marking this daemon start,
// giving the store real data to query even before any collector (eBPF,
// samplers) exists.
func recordStartupMarker(st store.Store) error {
	return st.WritePoints(context.Background(), []store.Point{{
		Metric:    "agentic_mcpd_start",
		Timestamp: time.Now(),
		Value:     1,
		Labels:    map[string]string{"version": "0.1.0"},
	}})
}

// startRetentionLoop runs the store's downsample job on a ticker for the
// lifetime of the process, consolidating raw points older than
// cfg.DB.Retention.Raw into hourly points, and hourly points older than
// cfg.DB.Retention.Hourly into daily points.
func startRetentionLoop(cfg config.Config, st store.Store) {
	interval := cfg.DB.Retention.Interval.Duration()
	if interval <= 0 {
		interval = time.Hour
	}
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			runDownsample(cfg, st)
		}
	}()
}

func runDownsample(cfg config.Config, st store.Store) {
	now := time.Now()
	rawCutoff := now.Add(-cfg.DB.Retention.Raw.Duration())
	hourlyCutoff := now.Add(-cfg.DB.Retention.Hourly.Duration())

	stats, err := st.Downsample(context.Background(), rawCutoff, hourlyCutoff)
	if err != nil {
		slog.Error("retention downsample failed", "error", err)
		return
	}
	if stats.RawRowsAggregated > 0 || stats.HourlyRowsAggregated > 0 {
		slog.Info("retention downsample completed",
			"raw_aggregated", stats.RawRowsAggregated,
			"hourly_created", stats.HourlyRowsCreated,
			"hourly_aggregated", stats.HourlyRowsAggregated,
			"daily_created", stats.DailyRowsCreated)
	}
}

// startProxyManager opens the durable satellite registry, loads this
// proxy's own client certificate, and starts polling every satellite —
// both statically configured (config.yaml's proxy.satellites) and
// dynamically enrolled (see fleet.SatelliteRegistry) — when mode: proxy is
// set (see docs/plan.md's "Three operating modes" / Selecta design). A
// no-op (nil, nil) when mode is not "proxy". Any setup failure is logged
// and degrades gracefully to (nil, nil), the same non-fatal posture the
// rest of this daemon's optional subsystems (eBPF, PAM) already follow —
// this agent's own MCP/REST functionality must keep working even if
// satellite polling can't start. The caller must Close both the returned
// registry and manager (in either order) when non-nil.
func startProxyManager(cfg config.Config, st store.Store) (*fleet.SatelliteRegistry, *fleet.Manager) {
	if cfg.Mode != "proxy" {
		return nil, nil
	}
	registry, err := fleet.OpenRegistry(cfg.Proxy.SatellitesPath)
	if err != nil {
		slog.Error("proxy mode: failed to open satellite registry, satellite polling disabled", "error", err)
		return nil, nil
	}
	clientCert, err := fleet.LoadClientCert(cfg.Proxy.ClientCertFile, cfg.Proxy.ClientKeyFile)
	if err != nil {
		slog.Error("proxy mode: failed to load this agent's client certificate, satellite polling disabled", "error", err)
		registry.Close()
		return nil, nil
	}
	manager := fleet.NewManager(registry, clientCert, st)
	if err := manager.Start(context.Background(), cfg.Proxy.Satellites); err != nil {
		slog.Error("proxy mode: failed to start satellite polling", "error", err)
		manager.Close()
		registry.Close()
		return nil, nil
	}
	return registry, manager
}

// loadProxyPublicKeyOrWarn reads this proxy's own client_cert_file's
// public key (see tlsauth.PublicKeyPEMFromCertFile) for the enrollment
// endpoint to hand out — only attempted when enrollment is actually
// configured (mode: proxy with a non-empty proxy.enroll_secret), and
// logged-not-fatal on failure, consistent with every other optional
// subsystem here: enrollment just won't be available, the rest of the
// daemon still starts.
func loadProxyPublicKeyOrWarn(cfg config.Config) []byte {
	if cfg.Mode != "proxy" || cfg.Proxy.EnrollSecret == "" {
		return nil
	}
	pem, err := tlsauth.PublicKeyPEMFromCertFile(cfg.Proxy.ClientCertFile)
	if err != nil {
		slog.Error("proxy mode: failed to read this proxy's own public key, enrollment endpoint disabled", "error", err)
		return nil
	}
	return pem
}

// loadCommandPolicyOrEmpty loads the pipeline command policy if the file
// exists, else falls back to an empty (allow-nothing) policy — the safe
// default when no commands.yaml is configured.
func loadCommandPolicyOrEmpty(path string) *pipeline.Policy {
	if _, err := os.Stat(path); err != nil {
		slog.Warn("command policy file not found, pipelines will allow no commands", "path", path)
		return pipeline.EmptyPolicy()
	}
	p, err := pipeline.LoadPolicy(path)
	if err != nil {
		slog.Warn("failed to load command policy, pipelines will allow no commands", "path", path, "error", err)
		return pipeline.EmptyPolicy()
	}
	return p
}
