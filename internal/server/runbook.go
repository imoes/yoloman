package server

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/mutkluge/agentic-mcp/internal/runbook"
)

// runbookRunRequest is the POST /api/v1/runbook/run body: a runbook to execute
// locally, seed params, and a dry_run flag.
type runbookRunRequest struct {
	Runbook runbook.Runbook `json:"runbook"`
	Params  map[string]any  `json:"params,omitempty"`
	DryRun  bool            `json:"dry_run,omitempty"`
}

// handleRunbookRun runs a runbook on this agent via the module registry — the
// standalone-host execution path behind the local frontend's runbook builder.
// A non-dry-run runbook can invoke writing modules, so it needs the write gate;
// dry_run previews are always allowed.
func handleRunbookRun(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if cfg.ModReg == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("module registry not configured"))
		return
	}
	var req runbookRunRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("invalid runbook body: %w", err))
		return
	}
	if len(req.Runbook.Steps) == 0 {
		writeError(w, http.StatusBadRequest, fmt.Errorf("runbook has no steps"))
		return
	}
	if !req.DryRun && !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("agent is read-only (write disabled) — only dry_run runbooks are allowed"))
		return
	}
	res := runbook.Run(r.Context(), cfg.ModReg, req.Runbook, req.Params, req.DryRun)
	writeJSON(w, http.StatusOK, res)
}
