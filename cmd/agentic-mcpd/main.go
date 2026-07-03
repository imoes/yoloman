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
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "agentic-mcpd:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("agentic-mcpd", flag.ContinueOnError)
	configPath := fs.String("config", "/etc/agentic-mcp/config.yaml", "path to config.yaml")
	stdio := fs.Bool("stdio", false, "serve MCP over stdio instead of Streamable HTTP")
	listen := fs.String("listen", "", "override the listen address from config")
	if err := fs.Parse(args); err != nil {
		return err
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
	startProxyPollLoop(cfg, st)

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
		ProcRoot: "/proc",
		ModReg:   comps.modReg,
		Tasks:    comps.taskList,
		Policy:   comps.policy,
		Store:    st,
		Write:    cfg.Write,
		Token:    cfg.Token,
		ACL:      acl,
		Sessions: sessions,
		PAMAuth:  pamAuth,
		EBPF:     collector,
		Audit:    al,
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

// startProxyPollLoop runs one background poll ticker per configured
// satellite when mode: proxy is set (see docs/plan.md's "Three operating
// modes"). Each tick pulls that satellite's metrics_dump for the interval
// since the previous poll and writes them into the local store labeled by
// satellite name. A no-op when mode is not "proxy".
func startProxyPollLoop(cfg config.Config, st store.Store) {
	if cfg.Mode != "proxy" {
		return
	}
	for _, sat := range cfg.Proxy.Satellites {
		interval := sat.PollInterval.Duration()
		if interval <= 0 {
			interval = time.Minute
		}
		p := &fleet.Puller{Satellite: sat, Store: st}
		go func() {
			ticker := time.NewTicker(interval)
			defer ticker.Stop()
			last := time.Now().Add(-interval)
			for range ticker.C {
				now := time.Now()
				n, err := p.PullOnce(context.Background(), last, now)
				if err != nil {
					slog.Error("satellite poll failed", "satellite", p.Satellite.Name, "error", err)
					continue
				}
				last = now
				if n > 0 {
					slog.Info("satellite poll completed", "satellite", p.Satellite.Name, "points", n)
				}
			}
		}()
	}
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
