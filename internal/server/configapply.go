package server

import (
	"encoding/json"
	"fmt"
	"net/http"
)

// handleConfigApply is the L4 push target: Bossman POSTs the compiled desired
// state here (server→agent, the single-firewall-rule direction). Write-gated,
// since applying pushed config is a write action. The JSON response is the
// ack the controller records — {status: "applied"|"unchanged", generation}.
func handleConfigApply(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("agent is read-only (write disabled) — cannot apply pushed config"))
		return
	}
	if cfg.DesiredState == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("desired-state store not configured"))
		return
	}
	var body struct {
		Generation int64           `json:"generation"`
		ConfigHash string          `json:"config_hash"`
		State      json.RawMessage `json:"state"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("invalid apply body: %w", err))
		return
	}
	if body.Generation <= 0 {
		writeError(w, http.StatusBadRequest, fmt.Errorf("generation must be > 0"))
		return
	}
	applied, err := cfg.DesiredState.Apply(body.Generation, body.ConfigHash, body.State)
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Errorf("applying desired state: %w", err))
		return
	}
	status := "unchanged"
	if applied {
		status = "applied"
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": status, "generation": body.Generation})
}
