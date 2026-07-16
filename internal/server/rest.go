package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/audit"
	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/collect"
	"github.com/mutkluge/agentic-mcp/internal/console"
	"github.com/mutkluge/agentic-mcp/internal/desiredstate"
	"github.com/mutkluge/agentic-mcp/internal/ebpf"
	"github.com/mutkluge/agentic-mcp/internal/fleet"
	"github.com/mutkluge/agentic-mcp/internal/inventory"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/piggyback"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/state"
	"github.com/mutkluge/agentic-mcp/internal/store"
	"github.com/mutkluge/agentic-mcp/internal/tasks"
)

// RESTConfig bundles everything the REST layer needs to serve the same
// capabilities as the MCP layer (see NewServer in cmd/agentic-mcpd) as plain
// JSON over HTTP, for callers/automation without an MCP client.
type RESTConfig struct {
	ProcRoot string
	ModReg   *modules.Registry
	// State is the server-as-a-document store (plan/apply/rollback of managed
	// resources with generation history) behind /api/v1/state/*.
	State  *state.Store
	Tasks  []*tasks.Task
	Policy *pipeline.Policy
	Store  store.Store
	Write  bool

	// UploadsDir and MaxUploadSize back PUT /api/v1/upload (see
	// docs/plan.md's "File upload (staging)").
	UploadsDir    string
	MaxUploadSize int64

	// ModulesDir is where pushed Starlark modules (POST /api/v1/modules/apply,
	// Block G3) are persisted so they survive a restart — the same directory
	// loadComponents loads at startup.
	ModulesDir string

	// AllowSelfUpdate gates POST /api/v1/agent/self-update — the agent-upgrade
	// carve-out that works even when Write is false (see selfupdate.go).
	// Default true; set allow_self_update:false to forbid remote upgrades.
	AllowSelfUpdate bool
	// Piggyback collectors report guests (Docker containers, Proxmox/vSphere
	// VMs) as their own hosts via GET /api/v1/hosts/overview — the CheckMK
	// piggyback idea. Empty = none.
	Piggyback []piggyback.Collector
	// ConsoleEnabled activates the interactive web shell at GET /api/v1/console
	// (a PTY over WebSocket — see internal/console). Default true.
	ConsoleEnabled bool
	// ConsoleCommand is the program spawned in the console PTY; empty uses
	// console.DefaultCommand (/bin/login, so the operator authenticates in the
	// terminal via PAM and the shell runs as that user, not the root agent).
	ConsoleCommand []string
	// UpdateStagingDir is where the pushed .deb is written before dpkg runs.
	// It MUST NOT be under /tmp or /var/tmp: the service runs with
	// PrivateTmp=true, so those paths are namespaced to this process and
	// invisible to the transient systemd-run unit that actually invokes dpkg
	// (which lives in the host namespace) — staging in /tmp made dpkg fail
	// with "cannot access archive: No such file or directory". Empty defaults
	// to /var/lib/agentic-mcp (created by the package, shared with the host).
	UpdateStagingDir string

	// Token is the shared, backward-compatible bearer token (also used for
	// /mcp) — matches resolve to the fixed authz.TokenIdentity. Present
	// here so REST can accept it as one of two valid credentials, the
	// other being a PAM-login session.
	Token string
	// Tokens holds additional named bearer tokens, each resolving to its
	// own Identity (see docs/plan.md's per-token RBAC design and
	// internal/authz.ResolveBearerToken) — the REST counterpart to
	// cmd/agentic-mcpd/http.go's MCP bearer-auth wiring, built via
	// config.Config.TokenEntries().
	Tokens []authz.TokenEntry
	// ACL, Sessions, and PAMAuth are all optional (nil disables the
	// corresponding feature): with ACL nil, only the write gate applies
	// (pre-step-8 behavior); with PAMAuth/Sessions nil, /api/v1/auth/login
	// is unavailable and only the bearer token authenticates.
	ACL      *authz.ACL
	Sessions *authz.SessionStore
	PAMAuth  *authz.PAMAuthenticator

	// EBPF is optional (nil if unsupported/disabled on this host — see
	// docs/plan.md's graceful-degradation requirement); when set, the
	// net/connections, net/top-talkers, and exec-events routes are mounted.
	EBPF *ebpf.Collector

	// DesiredState is the L4 desired-state store (the push target). Bossman
	// PUSHES compiled config to POST /api/v1/config/apply (the agent never
	// dials out); GET /api/v1/state reports the applied generation + hash.
	DesiredState *desiredstate.Applier

	// Audit is optional (nil disables audit logging).
	Audit *audit.Logger

	// Mode mirrors config.Config.Mode ("standalone"/"satellite"/"proxy") —
	// the enrollment endpoint and satellite management routes are only
	// mounted when this is "proxy" (a Selecta).
	Mode string
	// ProxyEnrollSecret, when non-empty (and Mode == "proxy" and
	// Write == true), activates POST /api/v1/enroll — see
	// docs/plan.md's Selecta enrollment design.
	ProxyEnrollSecret string
	// ProxyPublicKeyPEM is this proxy's own client_cert_file's public key,
	// PEM-encoded (see tlsauth.PublicKeyPEMFromCertFile), precomputed once
	// at startup and handed out by the enrollment endpoint — the identity
	// that will actually connect to a newly enrolled satellite, so no
	// separate enrollment keypair is needed.
	ProxyPublicKeyPEM []byte
	// SatelliteManager is non-nil only in proxy mode; backs both the
	// enrollment endpoint (Enroll) and GET/DELETE
	// /api/v1/proxy/satellites (List/Remove).
	SatelliteManager *fleet.Manager

	// HostName is this agent's own name (os.Hostname() at startup),
	// reported as the "host" field of its own entry in
	// GET /api/v1/hosts/overview.
	HostName string
	// CheckRegistry holds the latest result of every built-in and
	// configured check (see internal/collect), read by
	// GET /api/v1/hosts/overview. Never nil in practice (main.go always
	// constructs one), but a nil registry degrades to an empty checks
	// list rather than panicking.
	CheckRegistry *collect.CheckRegistry
	// SatelliteSnapshots is non-nil only in proxy mode; it holds the most
	// recently pulled GET /api/v1/hosts/overview snapshot of every
	// satellite this proxy polls (see internal/fleet.SnapshotCache), so a
	// proxy's own /api/v1/hosts/overview can report itself plus every
	// satellite behind it in one response — see docs/plan.md's
	// monitoring-cockpit ergänzung ("ein Endpoint der alle Hosts mit
	// ihren Metriken ausgibt").
	SatelliteSnapshots *fleet.SnapshotCache
	// Inventory is the cached HW/SW inventory collector (see
	// internal/inventory, Block H1) — optional (nil omits the inventory
	// field from GET /api/v1/hosts/overview).
	Inventory *inventory.Cached
}

type ctxKey int

const identityCtxKey ctxKey = iota

// identityFromRequest resolves the caller's authz.Identity from either a
// bearer token (the shared legacy token -> authz.TokenIdentity, or one of
// cfg.Tokens' named entries -> that entry's own Identity — see
// authz.ResolveBearerToken) or a session token/cookie created by a prior
// PAM login (-> the logged-in user's identity).
func identityFromRequest(r *http.Request, cfg RESTConfig) (authz.Identity, bool) {
	auth := r.Header.Get("Authorization")

	if cfg.Token != "" || len(cfg.Tokens) > 0 {
		const bearerPrefix = "Bearer "
		if strings.HasPrefix(auth, bearerPrefix) {
			given := auth[len(bearerPrefix):]
			if identity, ok := authz.ResolveBearerToken(given, cfg.Token, cfg.Tokens); ok {
				return identity, true
			}
		}
	}

	if cfg.Sessions != nil {
		const sessionPrefix = "Session "
		if strings.HasPrefix(auth, sessionPrefix) {
			return cfg.Sessions.Resolve(auth[len(sessionPrefix):])
		}
		if cookie, err := r.Cookie("session"); err == nil {
			return cfg.Sessions.Resolve(cookie.Value)
		}
	}

	return authz.Identity{}, false
}

// withIdentity requires every request but /api/v1/auth/login to present a
// valid bearer token or session (see identityFromRequest), attaching the
// resolved Identity to the request context. If neither a token nor session
// store is configured at all, authentication is skipped entirely — the
// same "auth disabled" dev-mode fallback used elsewhere in the daemon.
func withIdentity(cfg RESTConfig, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// /api/v1/enroll authenticates itself via its own shared
		// enroll_secret (see handleEnroll) — there is no bearer token or
		// session yet at the point a caller is trying to bootstrap trust,
		// same reasoning as the /api/v1/auth/login bypass below.
		if r.URL.Path == "/api/v1/auth/login" || r.URL.Path == "/api/v1/enroll" {
			next.ServeHTTP(w, r)
			return
		}
		if cfg.Token == "" && cfg.Sessions == nil {
			next.ServeHTTP(w, r)
			return
		}
		identity, ok := identityFromRequest(r, cfg)
		if !ok {
			writeError(w, http.StatusUnauthorized, fmt.Errorf("authentication required"))
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), identityCtxKey, identity)))
	})
}

func identityFromContext(ctx context.Context) authz.Identity {
	identity, _ := ctx.Value(identityCtxKey).(authz.Identity)
	return identity
}

// authorizeTool checks the ACL (if configured) for identity calling name,
// writing to the response and returning false if access is denied. If
// cfg.ACL is nil, ACL is not enforced — only the existing write gate
// applies, preserving pre-step-8 behavior for installs without PAM/ACL
// configured.
func authorizeTool(w http.ResponseWriter, r *http.Request, cfg RESTConfig, name string, writes bool) bool {
	if cfg.ACL == nil {
		return true
	}
	identity := identityFromContext(r.Context())
	dec, err := cfg.ACL.Authorize(r.Context(), identity, name, writes)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return false
	}
	if !dec.Allowed {
		writeError(w, http.StatusForbidden, fmt.Errorf("%s", dec.Reason))
		return false
	}
	return true
}

// NewRESTHandler builds the /api/v1/... REST router. Every route mirrors an
// MCP resource or tool 1:1 (proc resources, module/task tools, run_pipeline,
// metrics) so the two access modes carry identical capabilities.
func NewRESTHandler(cfg RESTConfig) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("POST /api/v1/auth/login", func(w http.ResponseWriter, r *http.Request) {
		handleLogin(w, r, cfg)
	})

	mux.HandleFunc("GET /api/v1/proc", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"resources": ProcResourceNames()})
	})
	mux.HandleFunc("GET /api/v1/proc/{name}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		data, ok, err := RenderProcResource(cfg.ProcRoot, name)
		if !ok {
			writeError(w, http.StatusNotFound, fmt.Errorf("unknown proc resource %q", name))
			return
		}
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(data)
	})

	mux.HandleFunc("GET /api/v1/tools", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"tools": listAvailableTools(cfg)})
	})
	mux.HandleFunc("POST /api/v1/tools/{name}", func(w http.ResponseWriter, r *http.Request) {
		handleToolCall(w, r, cfg)
	})

	mux.HandleFunc("GET /api/v1/metrics", func(w http.ResponseWriter, r *http.Request) {
		handleMetricsDump(w, r, cfg.Store)
	})
	mux.HandleFunc("GET /api/v1/metrics/{metric}", func(w http.ResponseWriter, r *http.Request) {
		handleMetricsQuery(w, r, cfg.Store)
	})
	RegisterConnectionsDumpRoute(mux, cfg.Store)
	mux.HandleFunc("POST /api/v1/runbook/run", func(w http.ResponseWriter, r *http.Request) {
		handleRunbookRun(w, r, cfg)
	})

	// Server-as-a-document: plan/apply/rollback with generation history.
	mux.HandleFunc("GET /api/v1/state/observed", func(w http.ResponseWriter, r *http.Request) { handleStateObserved(w, r, cfg) })
	mux.HandleFunc("POST /api/v1/state/plan", func(w http.ResponseWriter, r *http.Request) { handleStatePlan(w, r, cfg) })
	mux.HandleFunc("POST /api/v1/state/apply", func(w http.ResponseWriter, r *http.Request) { handleStateApply(w, r, cfg) })
	mux.HandleFunc("GET /api/v1/state/generations", func(w http.ResponseWriter, r *http.Request) { handleStateGenerations(w, r, cfg) })
	mux.HandleFunc("POST /api/v1/state/rollback", func(w http.ResponseWriter, r *http.Request) { handleStateRollback(w, r, cfg) })

	RegisterEnrollRoutes(mux, cfg)

	mux.HandleFunc("GET /api/v1/hosts/overview", func(w http.ResponseWriter, r *http.Request) {
		handleHostsOverview(w, r, cfg)
	})
	// F-9: the configured piggyback sources + their live status (read-only),
	// so the fleet UI can show which sources a host reports guests from.
	mux.HandleFunc("GET /api/v1/piggyback/sources", func(w http.ResponseWriter, r *http.Request) {
		handlePiggybackSources(w, r, cfg)
	})

	// Block L4: Bossman PUSHES the compiled desired state here (server→agent,
	// the single-firewall-rule direction). Write-gated — applying pushed
	// config is a write action. The response IS the ack the controller
	// records (status applied/unchanged + the stored generation).
	mux.HandleFunc("POST /api/v1/config/apply", func(w http.ResponseWriter, r *http.Request) {
		handleConfigApply(w, r, cfg)
	})
	// Read-only desired-state status (drift view) — which compiled
	// generation this agent has applied.
	mux.HandleFunc("GET /api/v1/state", func(w http.ResponseWriter, r *http.Request) {
		if cfg.DesiredState == nil {
			writeJSON(w, http.StatusOK, map[string]any{"desired_state": "unconfigured"})
			return
		}
		writeJSON(w, http.StatusOK, cfg.DesiredState.Status())
	})

	mux.HandleFunc("GET /api/v1/acl/tools/{name}", func(w http.ResponseWriter, r *http.Request) {
		handleGetToolACL(w, r, cfg)
	})
	mux.HandleFunc("PATCH /api/v1/acl/tools/{name}", func(w http.ResponseWriter, r *http.Request) {
		handleSetToolACL(w, r, cfg)
	})
	mux.HandleFunc("GET /api/v1/acl/rules", func(w http.ResponseWriter, r *http.Request) {
		handleListACLRules(w, r, cfg)
	})
	mux.HandleFunc("PUT /api/v1/acl/rules", func(w http.ResponseWriter, r *http.Request) {
		handleReplaceACLRules(w, r, cfg)
	})

	mux.HandleFunc("PUT /api/v1/upload", func(w http.ResponseWriter, r *http.Request) {
		handleUpload(w, r, cfg)
	})

	// Agent self-update (Block N-deploy): receives a new .deb and installs it
	// (dpkg -> postinst restart). Deliberately NOT write-gated — a read-only
	// agent must still be upgradable; gated by allow_self_update instead.
	// Starlark module delivery (Block G3): Bossman PUSHES translated .star
	// modules; the agent validates, persists, and live-registers them.
	mux.HandleFunc("POST /api/v1/modules/apply", func(w http.ResponseWriter, r *http.Request) {
		handleModulesApply(w, r, cfg)
	})

	mux.HandleFunc("POST /api/v1/agent/self-update", func(w http.ResponseWriter, r *http.Request) {
		handleSelfUpdate(w, r, cfg)
	})

	RegisterEBPFRoutes(mux, cfg.EBPF)
	RegisterProcessRoutes(mux, cfg)

	// Interactive web shell (Proxmox-style): a PTY running /bin/login, over a
	// WebSocket. Behind withIdentity + the outer mTLS wrapper; Bossman proxies
	// browsers to it with a per-host ACL check.
	if cfg.ConsoleEnabled {
		mux.Handle("GET /api/v1/console", console.Handler(cfg.ConsoleCommand))
	}

	return withIdentity(cfg, mux)
}

func handleLogin(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.PAMAuth == nil || cfg.Sessions == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("PAM login is not configured"))
		return
	}
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("decoding JSON body: %w", err))
		return
	}
	identity, err := cfg.PAMAuth.Authenticate(body.Username, body.Password)
	if err != nil {
		writeError(w, http.StatusUnauthorized, fmt.Errorf("login failed"))
		return
	}
	token, err := cfg.Sessions.Create(identity)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"session_token": token})
}

func handleGetToolACL(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.ACL == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("ACL is not configured"))
		return
	}
	name := r.PathValue("name")
	enabled, err := cfg.ACL.IsToolEnabled(r.Context(), name)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"name": name, "enabled": enabled})
}

func handleSetToolACL(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.ACL == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("ACL is not configured"))
		return
	}
	if !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("managing ACL state requires write=true"))
		return
	}
	name := r.PathValue("name")
	var body struct {
		Enabled bool `json:"enabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("decoding JSON body: %w", err))
		return
	}
	if err := cfg.ACL.SetToolEnabled(r.Context(), name, body.Enabled); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"name": name, "enabled": body.Enabled})
}

func handleListACLRules(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.ACL == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("ACL is not configured"))
		return
	}
	rules, err := cfg.ACL.ListRules(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"rules": rules})
}

func handleReplaceACLRules(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.ACL == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("ACL is not configured"))
		return
	}
	if !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("managing ACL rules requires write=true"))
		return
	}
	var body struct {
		Rules []authz.Rule `json:"rules"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("decoding JSON body: %w", err))
		return
	}

	existing, err := cfg.ACL.ListRules(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	for _, old := range existing {
		if err := cfg.ACL.DeleteRule(r.Context(), old.ID); err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
	}
	for _, newRule := range body.Rules {
		if _, err := cfg.ACL.AddRule(r.Context(), newRule); err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"rules": body.Rules})
}

// availableTool describes one callable REST tool for GET /api/v1/tools.
type availableTool struct {
	Name   string `json:"name"`
	Kind   string `json:"kind"` // "module" | "task" | "pipeline"
	Writes bool   `json:"writes"`
}

func listAvailableTools(cfg RESTConfig) []availableTool {
	var out []availableTool
	for _, m := range cfg.ModReg.All() {
		if m.Writes() && !cfg.Write {
			continue
		}
		out = append(out, availableTool{Name: m.Name(), Kind: "module", Writes: m.Writes()})
	}
	for _, t := range cfg.Tasks {
		writes, err := t.Writes(cfg.ModReg)
		if err != nil || (writes && !cfg.Write) {
			continue
		}
		kind := "task"
		if t.IsPipeline() {
			kind = "pipeline"
		}
		out = append(out, availableTool{Name: t.Name, Kind: kind, Writes: writes})
	}
	if cfg.Write {
		out = append(out, availableTool{Name: "run_pipeline", Kind: "pipeline", Writes: true})
	}
	return out
}

func handleToolCall(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	name := r.PathValue("name")
	start := time.Now()
	identity := identityLabel(identityFromContext(r.Context()))

	var params map[string]any
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&params); err != nil {
			writeError(w, http.StatusBadRequest, fmt.Errorf("decoding JSON body: %w", err))
			return
		}
	}

	if name == "run_pipeline" {
		if !cfg.Write {
			writeError(w, http.StatusForbidden, fmt.Errorf("run_pipeline is disabled (write=false)"))
			return
		}
		if !authorizeTool(w, r, cfg, name, true) {
			return
		}
		stages, err := decodePipelineStages(params["stages"])
		if err != nil {
			cfg.Audit.LogCall(identity, name, true, false, params, start, err)
			writeError(w, http.StatusBadRequest, err)
			return
		}
		res, err := pipeline.Run(r.Context(), cfg.Policy, stages, 0, 0)
		cfg.Audit.LogCall(identity, name, true, err == nil, params, start, err)
		if err != nil {
			writeError(w, http.StatusUnprocessableEntity, err)
			return
		}
		writeJSON(w, http.StatusOK, res)
		return
	}

	if m, ok := cfg.ModReg.Get(name); ok {
		if m.Writes() && !cfg.Write {
			writeError(w, http.StatusForbidden, fmt.Errorf("tool %q is disabled (write=false)", name))
			return
		}
		if !authorizeTool(w, r, cfg, name, m.Writes()) {
			return
		}
		// A caller may request a preview with "dry_run": true — a write module
		// then computes what would change without touching the host (config's
		// merge, template_render, …). Absent/false keeps always-apply.
		dryRun, _ := params["dry_run"].(bool)
		res, err := m.Run(r.Context(), params, dryRun)
		cfg.Audit.LogCall(identity, name, m.Writes(), res.Changed, params, start, err)
		if err != nil {
			writeError(w, http.StatusUnprocessableEntity, err)
			return
		}
		writeJSON(w, http.StatusOK, res)
		return
	}

	for _, t := range cfg.Tasks {
		if t.Name != name {
			continue
		}
		writes, err := t.Writes(cfg.ModReg)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		if writes && !cfg.Write {
			writeError(w, http.StatusForbidden, fmt.Errorf("tool %q is disabled (write=false)", name))
			return
		}
		if !authorizeTool(w, r, cfg, name, writes) {
			return
		}
		res, err := t.Run(r.Context(), cfg.ModReg, cfg.Policy, params, false)
		cfg.Audit.LogCall(identity, name, writes, res.Changed, params, start, err)
		if err != nil {
			writeError(w, http.StatusUnprocessableEntity, err)
			return
		}
		writeJSON(w, http.StatusOK, res)
		return
	}

	writeError(w, http.StatusNotFound, fmt.Errorf("unknown tool %q", name))
}

func decodePipelineStages(raw any) ([][]string, error) {
	stagesRaw, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("stages: expected an array of argv arrays")
	}
	stages := make([][]string, len(stagesRaw))
	for i, stageRaw := range stagesRaw {
		argvRaw, ok := stageRaw.([]any)
		if !ok {
			return nil, fmt.Errorf("stages[%d]: expected an array of strings", i)
		}
		argv := make([]string, len(argvRaw))
		for j, a := range argvRaw {
			s, ok := a.(string)
			if !ok {
				return nil, fmt.Errorf("stages[%d][%d]: expected a string", i, j)
			}
			argv[j] = s
		}
		stages[i] = argv
	}
	return stages, nil
}

func handleMetricsQuery(w http.ResponseWriter, r *http.Request, st store.Store) {
	metric := r.PathValue("metric")
	q := r.URL.Query()

	now := time.Now()
	from, err := parseTimeBound(q.Get("from"), now, -time.Hour)
	if err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("from: %w", err))
		return
	}
	to, err := parseTimeBound(q.Get("to"), now, 0)
	if err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("to: %w", err))
		return
	}
	resolution := store.ResolutionRaw
	if res := q.Get("resolution"); res != "" {
		resolution = store.Resolution(res)
	}

	labels := map[string]string{}
	for key, vals := range q {
		if rest, ok := strings.CutPrefix(key, "label."); ok && len(vals) > 0 {
			labels[rest] = vals[0]
		}
	}

	points, err := st.Query(r.Context(), metric, from, to, labels, resolution)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	out := make([]MetricPoint, len(points))
	for i, p := range points {
		out[i] = MetricPoint{Timestamp: p.Timestamp.Format(time.RFC3339), Value: p.Value, Labels: p.Labels}
	}
	writeJSON(w, http.StatusOK, MetricsQueryOutput{Points: out})
}

// handleMetricsDump serves the bulk metrics_dump equivalent: every known
// metric in one response, the efficient path for satellite/proxy pulling
// (see docs/plan.md's three operating modes).
func handleMetricsDump(w http.ResponseWriter, r *http.Request, st store.Store) {
	q := r.URL.Query()

	now := time.Now()
	from, err := parseTimeBound(q.Get("from"), now, -time.Hour)
	if err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("from: %w", err))
		return
	}
	to, err := parseTimeBound(q.Get("to"), now, 0)
	if err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("to: %w", err))
		return
	}
	resolution := store.ResolutionRaw
	if res := q.Get("resolution"); res != "" {
		resolution = store.Resolution(res)
	}

	metrics, err := dumpAllMetrics(r.Context(), st, from, to, resolution)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, MetricsDumpOutput{Metrics: metrics})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}
