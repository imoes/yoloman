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
	"path/filepath"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/audit"
	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/checks"
	"github.com/mutkluge/agentic-mcp/internal/collect"
	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/desiredstate"
	"github.com/mutkluge/agentic-mcp/internal/ebpf"
	"github.com/mutkluge/agentic-mcp/internal/fleet"
	"github.com/mutkluge/agentic-mcp/internal/inventory"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/server"
	"github.com/mutkluge/agentic-mcp/internal/starmodules"
	"github.com/mutkluge/agentic-mcp/internal/starmodules/embedded"
	"github.com/mutkluge/agentic-mcp/internal/store"
	"github.com/mutkluge/agentic-mcp/internal/tasks"
	"github.com/mutkluge/agentic-mcp/internal/tlsauth"
)

// version is the agent build version, stamped at build time via
// -ldflags "-X main.version=$(cat VERSION)". Reported at startup and by
// GET /healthz so an operator can tell which build a host is running (bump
// VERSION on every agent change so deployed .debs are distinguishable).
var version = "dev"

// Version exposes the build version to the rest of the daemon (e.g. /healthz).
func Version() string { return version }

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
	showVersion := fs.Bool("version", false, "print the agent version and exit")
	generateToken := fs.Bool("generate-token", false, "print a new cryptographically random bearer token and exit")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *showVersion {
		fmt.Println(version)
		return nil
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

	// Block L4: the desired-state store — Bossman PUSHES compiled config into
	// it via POST /api/v1/config/apply (the agent never dials out). Created
	// before the collect loop so that loop can read the pushed thresholds
	// (behavioral apply) each tick. The applied state persists next to the DB
	// file across restarts.
	dsApplier := desiredstate.NewApplier(filepath.Join(filepath.Dir(cfg.DB.Path), "desired-state.json"))

	checkRegistry := collect.NewCheckRegistry()
	startCollectLoop(cfg, st, checkRegistry, dsApplier)
	startConfiguredCheckLoops(cfg, st, checkRegistry)

	hostName, err := os.Hostname()
	if err != nil {
		hostName = "unknown"
		slog.Warn("determining hostname failed, GET /api/v1/hosts/overview will report it as \"unknown\"", "error", err)
	}

	proxyRegistry, satelliteManager, satelliteSnapshots := startProxyManager(cfg, st)
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
		ProcRoot:           "/proc",
		ModReg:             comps.modReg,
		Tasks:              comps.taskList,
		Policy:             comps.policy,
		Store:              st,
		Write:              cfg.Write,
		Token:              cfg.Token,
		Tokens:             cfg.TokenEntries(),
		ACL:                acl,
		Sessions:           sessions,
		PAMAuth:            pamAuth,
		EBPF:               collector,
		DesiredState:       dsApplier,
		Audit:              al,
		UploadsDir:         cfg.UploadsDir,
		ModulesDir:         cfg.ModulesDir,
		MaxUploadSize:      cfg.MaxUploadSize,
		AllowSelfUpdate:    cfg.AllowSelfUpdate,
		ConsoleEnabled:     cfg.Console.Enabled,
		ConsoleCommand:     cfg.Console.Command,
		Mode:               cfg.Mode,
		ProxyEnrollSecret:  cfg.Proxy.EnrollSecret,
		ProxyPublicKeyPEM:  proxyPublicKeyPEM,
		SatelliteManager:   satelliteManager,
		HostName:           hostName,
		CheckRegistry:      checkRegistry,
		SatelliteSnapshots: satelliteSnapshots,
		// HW/SW inventory (Block H1): near-static, cached for an hour so
		// the overview endpoint never re-walks sysfs per poll tick.
		Inventory: inventory.NewCached(inventory.DefaultCollector(), time.Hour),
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
	modReg := server.NewDefaultModuleRegistry()

	// Block J4 / Item 3c: register the curated built-in Starlark module set
	// baked into the binary (go:embed) — the network module + storage stack
	// the host-management page depends on. Always present (no push, no on-disk
	// modules.d needed); same registry, so they dispatch like native modules.
	if embFS, embErr := embedded.FS(); embErr != nil {
		slog.Warn("embedded modules unavailable", "reason", embErr.Error())
	} else {
		embMods, embWarn, embLoadErr := starmodules.LoadFS(embFS, cfg.Write)
		if embLoadErr != nil {
			return nil, fmt.Errorf("loading embedded modules: %w", embLoadErr)
		}
		for _, w := range embWarn {
			slog.Warn("skipping embedded module", "reason", w)
		}
		for _, m := range embMods {
			if regErr := modReg.Register(m); regErr != nil {
				slog.Warn("skipping embedded module", "reason", regErr.Error())
			}
		}
		if len(embMods) > 0 {
			slog.Info("loaded embedded Starlark modules", "count", len(embMods))
		}
	}

	// Block G3: register translated Starlark collection modules from
	// modules_dir into the SAME registry the REST/MCP layers read, so they
	// dispatch like native modules. Invalid modules are logged and skipped,
	// never fatal (one bad module must not stop the agent).
	starMods, warnings, err := starmodules.LoadDir(cfg.ModulesDir, cfg.Write)
	if err != nil {
		return nil, fmt.Errorf("loading modules.d: %w", err)
	}
	for _, w := range warnings {
		slog.Warn("skipping Starlark module", "reason", w)
	}
	for _, m := range starMods {
		if regErr := modReg.Register(m); regErr != nil {
			slog.Warn("skipping Starlark module", "reason", regErr.Error())
		}
	}
	if len(starMods) > 0 {
		slog.Info("loaded Starlark modules", "count", len(starMods), "dir", cfg.ModulesDir)
	}

	return &components{
		modReg:   modReg,
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
	server.RegisterProcessList(s, "/proc", collector)
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

// startCollectLoop runs internal/collect's /proc sampler on a ticker for
// the lifetime of the process: every tick, it writes the sampled
// CPU/memory/disk/uptime/network points into the store (exactly like any
// other metric, so they're gettable via the existing metrics_dump/
// metrics_query tools) and records the derived built-in checks
// (CPU load/memory/disk/uptime) into checkReg for GET
// /api/v1/hosts/overview — see docs/plan.md's monitoring-cockpit
// ergänzung. This is the fix for the agent previously writing no real
// metric beyond the one-shot startup marker.
func startCollectLoop(cfg config.Config, st store.Store, checkReg *collect.CheckRegistry, dsApplier *desiredstate.Applier) {
	if !cfg.Collect.Enabled {
		slog.Warn("metric collection disabled (collect.enabled: false) — GET /api/v1/hosts/overview will report no metrics/checks")
		return
	}
	interval := cfg.Collect.Interval.Duration()
	if interval <= 0 {
		interval = 30 * time.Second
	}
	// Block C2b: a stateful CPU-utilization meter — busy% needs a jiffy delta
	// across ticks, so it lives here (not in the pure Sample()) and is primed
	// on the first tick.
	cpuMeter := &collect.CPUMeter{}
	// Block J3: per-container Docker metrics on the same tick (nil when
	// disabled). Degrades silently when the socket is absent.
	var dockerCollector *collect.DockerCollector
	if cfg.Collect.Docker {
		dockerCollector = collect.NewDockerCollector(cfg.Collect.DockerSocket)
	}
	runOnce := func() {
		now := time.Now()
		// Block L4-behavioral: read the pushed thresholds fresh each tick, so a
		// new generation Bossman pushes takes effect on the next sample with no
		// restart. Empty when nothing has been pushed yet → built-in defaults.
		snap, err := collect.SampleDefault("/proc", now, desiredStateOverrides(dsApplier))
		if err != nil {
			slog.Error("metric sampling failed", "error", err)
			return
		}
		points := snap.Points
		for _, c := range snap.Checks {
			checkReg.Set(c.Name, c.Result, c.At)
			points = append(points, store.Point{
				Metric:    collect.CheckStatusMetricName(c.Name),
				Timestamp: c.At,
				Value:     collect.StatusValue(c.Status),
			})
		}
		// cpu_pct: only once the meter has two readings to rate against.
		if pct, ok := cpuMeter.Sample("/proc"); ok {
			points = append(points, store.Point{Metric: "cpu_pct", Timestamp: now, Value: pct})
		}
		if dockerCollector != nil {
			if dpts, derr := dockerCollector.Sample(now); derr != nil {
				slog.Debug("docker metric sampling failed", "error", derr)
			} else {
				points = append(points, dpts...)
			}
		}
		if err := st.WritePoints(context.Background(), points); err != nil {
			slog.Error("writing sampled metrics failed", "error", err)
		}
	}
	runOnce() // don't wait a full interval before the first real data point exists
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			runOnce()
		}
	}()
}

// desiredStateOverrides converts the applier's pushed thresholds into the
// collect package's override type, so collect stays decoupled from
// desiredstate. A nil applier or no applied state yields an empty map (→
// built-in defaults). Only the fields the built-in checks use (warn/crit) are
// carried across.
func desiredStateOverrides(a *desiredstate.Applier) map[string]collect.ThresholdOverride {
	if a == nil {
		return nil
	}
	out := map[string]collect.ThresholdOverride{}
	for metric, th := range a.Thresholds() {
		out[metric] = collect.ThresholdOverride{Warn: th.Warn, Crit: th.Crit}
	}
	return out
}

// startConfiguredCheckLoops runs each cfg.Checks entry (an external
// Nagios/CheckMK-plugin-style command) on its own ticker, recording every
// result into the same checkReg the built-in checks use — so an operator's
// custom checks show up in GET /api/v1/hosts/overview identically to the
// built-in ones, and are equally graphable via their check_<name>_state
// metric.
func startConfiguredCheckLoops(cfg config.Config, st store.Store, checkReg *collect.CheckRegistry) {
	for _, spec := range cfg.Checks {
		spec := spec
		interval := spec.Interval.Duration()
		if interval <= 0 {
			interval = time.Minute
		}
		timeout := spec.Timeout.Duration()

		runOnce := func() {
			now := time.Now()
			result, err := checks.RunDefault(context.Background(), spec.Command, timeout)
			if err != nil {
				slog.Error("configured check failed to execute", "check", spec.Name, "error", err)
				return
			}
			checkReg.Set(spec.Name, result, now)
			if err := st.WritePoints(context.Background(), []store.Point{{
				Metric:    collect.CheckStatusMetricName(spec.Name),
				Timestamp: now,
				Value:     collect.StatusValue(result.Status),
			}}); err != nil {
				slog.Error("writing configured check state metric failed", "check", spec.Name, "error", err)
			}
		}
		runOnce()
		go func() {
			ticker := time.NewTicker(interval)
			defer ticker.Stop()
			for range ticker.C {
				runOnce()
			}
		}()
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
// registry and manager (in either order) when non-nil. The returned
// SnapshotCache (nil alongside the other two on any failure/non-proxy
// case) holds every satellite's latest GET /api/v1/hosts/overview
// snapshot, kept fresh by the Manager's own polling ticker — see
// docs/plan.md's monitoring-cockpit ergänzung.
func startProxyManager(cfg config.Config, st store.Store) (*fleet.SatelliteRegistry, *fleet.Manager, *fleet.SnapshotCache) {
	if cfg.Mode != "proxy" {
		return nil, nil, nil
	}
	registry, err := fleet.OpenRegistry(cfg.Proxy.SatellitesPath)
	if err != nil {
		slog.Error("proxy mode: failed to open satellite registry, satellite polling disabled", "error", err)
		return nil, nil, nil
	}
	clientCert, err := fleet.LoadClientCert(cfg.Proxy.ClientCertFile, cfg.Proxy.ClientKeyFile)
	if err != nil {
		slog.Error("proxy mode: failed to load this agent's client certificate, satellite polling disabled", "error", err)
		registry.Close()
		return nil, nil, nil
	}
	snapshotCache := fleet.NewSnapshotCache()
	manager := fleet.NewManager(registry, clientCert, st, snapshotCache)
	if err := manager.Start(context.Background(), cfg.Proxy.Satellites); err != nil {
		slog.Error("proxy mode: failed to start satellite polling", "error", err)
		manager.Close()
		registry.Close()
		return nil, nil, nil
	}
	return registry, manager, snapshotCache
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
