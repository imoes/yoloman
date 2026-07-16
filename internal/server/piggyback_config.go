package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"

	"gopkg.in/yaml.v3"

	"github.com/mutkluge/agentic-mcp/internal/config"
)

// F-9: add/remove a remote piggyback source (Proxmox/vSphere endpoint) at
// runtime. The handler persists the change to config.yaml and reloads the live
// collector Store — no agent restart. Write-gated (it mutates config +
// credentials). Docker/libvirt are local auto-detected sources, not managed
// here; only the remote API endpoints are add/removable.

type piggybackSourceReq struct {
	Type     string `json:"type"`     // proxmox | vsphere
	Host     string `json:"host"`     // host or host:port
	User     string `json:"user"`     // e.g. monitoring@pam
	Password string `json:"password"` // stored in the agent's root-owned config.yaml
	Insecure bool   `json:"insecure"` // skip TLS verify (self-signed certs)
}

func handlePiggybackAdd(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("agent is read-only (write disabled) — cannot add a piggyback source"))
		return
	}
	if cfg.ConfigPath == "" || cfg.Piggyback == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("piggyback configuration is not writable on this agent"))
		return
	}
	var req piggybackSourceReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("invalid body: %w", err))
		return
	}
	if req.Type != "proxmox" && req.Type != "vsphere" {
		writeError(w, http.StatusUnprocessableEntity, fmt.Errorf("type must be proxmox or vsphere"))
		return
	}
	if req.Host == "" {
		writeError(w, http.StatusUnprocessableEntity, fmt.Errorf("host is required"))
		return
	}

	loaded, err := config.Load(cfg.ConfigPath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Errorf("loading config: %w", err))
		return
	}
	ep := config.ProxmoxEndpoint{Host: req.Host, User: req.User, Password: req.Password, Insecure: req.Insecure}
	if req.Type == "proxmox" {
		loaded.Piggyback.Proxmox = upsertEndpoint(loaded.Piggyback.Proxmox, ep)
	} else {
		loaded.Piggyback.VSphere = upsertEndpoint(loaded.Piggyback.VSphere, config.VSphereEndpoint(ep))
	}
	if err := writeConfigFile(cfg.ConfigPath, loaded); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Errorf("writing config: %w", err))
		return
	}
	cfg.Piggyback.Reload(loaded)
	writeJSON(w, http.StatusOK, map[string]any{"added": req.Type, "host": req.Host})
}

func handlePiggybackRemove(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("agent is read-only (write disabled) — cannot remove a piggyback source"))
		return
	}
	if cfg.ConfigPath == "" || cfg.Piggyback == nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Errorf("piggyback configuration is not writable on this agent"))
		return
	}
	typ := r.URL.Query().Get("type")
	host := r.URL.Query().Get("host")
	if (typ != "proxmox" && typ != "vsphere") || host == "" {
		writeError(w, http.StatusUnprocessableEntity, fmt.Errorf("type (proxmox|vsphere) and host query params are required"))
		return
	}
	loaded, err := config.Load(cfg.ConfigPath)
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Errorf("loading config: %w", err))
		return
	}
	if typ == "proxmox" {
		loaded.Piggyback.Proxmox = removeEndpoint(loaded.Piggyback.Proxmox, host)
	} else {
		loaded.Piggyback.VSphere = removeEndpoint(loaded.Piggyback.VSphere, host)
	}
	if err := writeConfigFile(cfg.ConfigPath, loaded); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Errorf("writing config: %w", err))
		return
	}
	cfg.Piggyback.Reload(loaded)
	writeJSON(w, http.StatusOK, map[string]any{"removed": typ, "host": host})
}

// endpoint is the shared shape of Proxmox/vSphere endpoints (identical fields),
// so upsert/remove work over both via a tiny type set.
type endpoint interface {
	config.ProxmoxEndpoint | config.VSphereEndpoint
}

func hostOf[E endpoint](e E) string {
	switch v := any(e).(type) {
	case config.ProxmoxEndpoint:
		return v.Host
	case config.VSphereEndpoint:
		return v.Host
	}
	return ""
}

// upsertEndpoint replaces an endpoint with the same host, or appends it.
func upsertEndpoint[E endpoint](list []E, ep E) []E {
	for i := range list {
		if hostOf(list[i]) == hostOf(ep) {
			list[i] = ep
			return list
		}
	}
	return append(list, ep)
}

func removeEndpoint[E endpoint](list []E, host string) []E {
	out := list[:0:0]
	for _, e := range list {
		if hostOf(e) != host {
			out = append(out, e)
		}
	}
	return out
}

func writeConfigFile(path string, cfg config.Config) error {
	out, err := yaml.Marshal(&cfg)
	if err != nil {
		return err
	}
	return os.WriteFile(path, out, 0o600)
}
