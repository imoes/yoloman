package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/config"
)

// scheduleSelfConfigRestart bounces the service in a TRANSIENT systemd unit that survives our own
// restart — KillMode=control-group would otherwise take this child down with us, the same trap
// self-update handles. A package var so tests can substitute a no-op and still assert the restart was
// scheduled. The sleep lets the HTTP response flush before the restart lands.
var scheduleSelfConfigRestart = func() error {
	return exec.Command("systemd-run", "--collect", "--unit=agentic-mcp-selfconfig", "/bin/sh", "-c",
		"sleep 1; systemctl restart agentic-mcp.service").Start()
}

// collectConfigReq is a partial patch of the metric-collection knobs. Every field is a POINTER so an
// absent field ("leave it alone") is distinguishable from one explicitly set to false or empty: a
// request carrying only `services` must not also blank out `drop_metrics`.
type collectConfigReq struct {
	Services    *bool     `json:"services"`
	PSI         *bool     `json:"psi"`
	Docker      *bool     `json:"docker"`
	DRBDDevices *bool     `json:"drbd_devices"`
	DropMetrics *[]string `json:"drop_metrics"`
	Interval    *string   `json:"interval"` // a Go duration string, e.g. "60s"
}

// handleCollectConfig changes this agent's metric-collection settings and restarts to apply them.
//
// This is the counterpart to self-update for CONFIG, and it exists for one concrete reason: an
// operator can push a new binary to a read-only (write=false) agent but had no way to change what it
// collects, so turning off an unread, high-cardinality family like service_* required SSH to every
// host. Now Bossman can do it over the same authenticated channel it already uses.
//
// Two safety properties, both structural rather than promised:
//
//   - SCOPE. It writes ONLY the fields under `collect:`. It cannot touch listen, token, tls, write, or
//     any auth setting — the request type has no field for them and the handler copies the loaded
//     config forward for everything else. So even with the gate wide open it cannot escalate privilege
//     or lock the operator out.
//   - GATE. Like self-update it is deliberately NOT behind the master write gate (a read-only agent
//     must stay manageable, and a write:false agent could otherwise never be reconfigured — the
//     setting that would enable it is itself in the config). It is gated by allow_self_config
//     (default true) and, like every route, sits behind mTLS + the pinned-bearer auth, so only
//     Bossman's identity reaches it.
//
// A restart, not a live reload: the service collector is built once at startup from cfg.Collect.Services
// and drop_metrics is read when the sample loop is constructed, so writing the file alone changes
// nothing running. The restart uses the same transient-systemd-unit trick as self-update, so the
// restart cannot kill the child that triggers it.
func handleCollectConfig(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if !cfg.AllowSelfConfig {
		writeError(w, http.StatusForbidden, fmt.Errorf("self-config is disabled on this agent (allow_self_config: false)"))
		return
	}
	if cfg.ConfigPath == "" {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("this agent has no writable config path"))
		return
	}
	var req collectConfigReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("invalid body: %w", err))
		return
	}

	loaded, err := config.Load(cfg.ConfigPath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Errorf("loading config: %w", err))
		return
	}

	changed := map[string]any{}
	if req.Services != nil {
		loaded.Collect.Services = *req.Services
		changed["services"] = *req.Services
	}
	if req.PSI != nil {
		loaded.Collect.PSI = *req.PSI
		changed["psi"] = *req.PSI
	}
	if req.Docker != nil {
		loaded.Collect.Docker = *req.Docker
		changed["docker"] = *req.Docker
	}
	if req.DRBDDevices != nil {
		loaded.Collect.DRBDDevices = *req.DRBDDevices
		changed["drbd_devices"] = *req.DRBDDevices
	}
	if req.DropMetrics != nil {
		loaded.Collect.DropMetrics = *req.DropMetrics
		changed["drop_metrics"] = *req.DropMetrics
	}
	if req.Interval != nil {
		d, perr := time.ParseDuration(*req.Interval)
		if perr != nil || d <= 0 {
			writeError(w, http.StatusUnprocessableEntity, fmt.Errorf("interval %q is not a positive duration", *req.Interval))
			return
		}
		loaded.Collect.Interval = config.Duration(d)
		changed["interval"] = d.String()
	}

	if len(changed) == 0 {
		// Nothing to do, and therefore no restart — a no-op must not bounce the agent.
		writeJSON(w, http.StatusOK, map[string]any{"status": "unchanged"})
		return
	}

	// Validate the whole config before writing: a bad combination should be refused here, not
	// discovered when the restarted agent fails to load its own file and stays down.
	if verr := loaded.Validate(); verr != nil {
		writeError(w, http.StatusUnprocessableEntity, fmt.Errorf("resulting config is invalid: %w", verr))
		return
	}
	if err := writeConfigFile(cfg.ConfigPath, loaded); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Errorf("writing config: %w", err))
		return
	}

	if err := scheduleSelfConfigRestart(); err != nil {
		// The file is already written; report that so a caller knows a manual restart applies it.
		writeError(w, http.StatusInternalServerError,
			fmt.Errorf("config written but scheduling the restart failed (%w) — restart agentic-mcp manually to apply", err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "accepted",
		"changed": changed,
		"detail":  "config written; the service will restart to apply",
	})
}
