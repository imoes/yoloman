package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

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
}

// NewRESTHandler builds the /api/v1/... REST router. Every route mirrors an
// MCP resource or tool 1:1 (proc resources, module/task tools, run_pipeline,
// metrics) so the two access modes carry identical capabilities.
func NewRESTHandler(cfg RESTConfig) http.Handler {
	mux := http.NewServeMux()

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

	return mux
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
