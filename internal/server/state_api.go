package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/state"
)

// handleStateObserved renders the whole server as one JSON document: enabled
// services + the current content of every config file they reference
// (discovered via systemd units, read structured where a codec exists). The
// "GET the server as JSON" side of the model.
func handleStateObserved(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.ModReg == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("module registry not configured"))
		return
	}
	obs, err := state.Observe(r.Context(), cfg.ModReg, time.Now().UTC())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, obs)
}

// The server-as-a-document endpoints (Block "1"): plan a desired Document
// (diff observed → desired), apply it (converge + record a generation), list
// the generation history, and roll back to any earlier generation. Local to
// the agent — the standalone apex of "the server is a JSON document".

func handleStatePlan(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.State == nil || cfg.ModReg == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("state store not configured"))
		return
	}
	var doc state.Document
	if err := json.NewDecoder(r.Body).Decode(&doc); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("invalid state document: %w", err))
		return
	}
	writeJSON(w, http.StatusOK, cfg.State.Plan(r.Context(), cfg.ModReg, doc))
}

func handleStateApply(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.State == nil || cfg.ModReg == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("state store not configured"))
		return
	}
	var body struct {
		state.Document
		DryRun bool `json:"dry_run"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("invalid state document: %w", err))
		return
	}
	if !body.DryRun && !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("agent is read-only (write disabled) — only dry_run applies are allowed"))
		return
	}
	plan, gen, err := cfg.State.Apply(r.Context(), cfg.ModReg, body.Document, body.DryRun)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"plan": plan, "generation": gen, "dry_run": body.DryRun})
}

func handleStateGenerations(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.State == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("state store not configured"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"generations": cfg.State.Generations()})
}

func handleStateRollback(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.State == nil || cfg.ModReg == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("state store not configured"))
		return
	}
	var body struct {
		Generation int64 `json:"generation"`
		DryRun     bool  `json:"dry_run"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("invalid rollback body: %w", err))
		return
	}
	if !body.DryRun && !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("agent is read-only (write disabled) — only dry_run rollbacks are allowed"))
		return
	}
	plan, gen, err := cfg.State.Rollback(r.Context(), cfg.ModReg, body.Generation, body.DryRun)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"plan": plan, "generation": gen, "rolled_back_to": body.Generation, "dry_run": body.DryRun})
}
