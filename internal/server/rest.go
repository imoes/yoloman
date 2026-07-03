package server

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/ebpf"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/store"
	"github.com/mutkluge/agentic-mcp/internal/tasks"
)

// RESTConfig bundles everything the REST layer needs to serve the same
// capabilities as the MCP layer (see NewServer in cmd/agentic-mcpd) as plain
// JSON over HTTP, for callers/automation without an MCP client.
type RESTConfig struct {
	ProcRoot string
	ModReg   *modules.Registry
	Tasks    []*tasks.Task
	Policy   *pipeline.Policy
	Store    store.Store
	Write    bool

	// Token is the shared bearer token (also used for /mcp). Present here
	// so REST can accept it as one of two valid credentials, the other
	// being a PAM-login session.
	Token string
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
}

type ctxKey int

const identityCtxKey ctxKey = iota

// identityFromRequest resolves the caller's authz.Identity from either the
// shared bearer token (-> authz.TokenIdentity) or a session token/cookie
// created by a prior PAM login (-> the logged-in user's identity).
func identityFromRequest(r *http.Request, cfg RESTConfig) (authz.Identity, bool) {
	auth := r.Header.Get("Authorization")

	if cfg.Token != "" {
		const bearerPrefix = "Bearer "
		if strings.HasPrefix(auth, bearerPrefix) {
			given := auth[len(bearerPrefix):]
			if subtle.ConstantTimeCompare([]byte(given), []byte(cfg.Token)) == 1 {
				return authz.TokenIdentity, true
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
		if r.URL.Path == "/api/v1/auth/login" {
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

	mux.HandleFunc("GET /api/v1/metrics/{metric}", func(w http.ResponseWriter, r *http.Request) {
		handleMetricsQuery(w, r, cfg.Store)
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

	RegisterEBPFRoutes(mux, cfg.EBPF)

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
			writeError(w, http.StatusBadRequest, err)
			return
		}
		res, err := pipeline.Run(r.Context(), cfg.Policy, stages, 0, 0)
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
		res, err := m.Run(r.Context(), params, false)
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

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}
