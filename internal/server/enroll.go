package server

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/enroll"
)

// RegisterEnrollRoutes mounts POST /api/v1/enroll and the satellite-
// management routes (GET/DELETE /api/v1/proxy/satellites) onto mux — only
// when this agent is acting as a Selecta (proxy mode) with enrollment
// actually configured. A standalone Duppy or a satellite-mode agent has
// none of this: it registers *with* a Selecta or Bossman via
// `agentic-mcpd register`, it doesn't accept enrollments itself.
//
// Deliberately gated behind both cfg.Write and a non-empty
// ProxyEnrollSecret — enrolling a satellite is a real, persistent state
// mutation (it makes this proxy poll a new remote endpoint on an ongoing
// basis), so it follows the same write-gate discipline as every other
// mutating capability in this project, no exception for being REST-only.
func RegisterEnrollRoutes(mux *http.ServeMux, cfg RESTConfig) {
	if cfg.Mode != "proxy" || cfg.SatelliteManager == nil {
		return
	}
	mux.HandleFunc("GET /api/v1/proxy/satellites", func(w http.ResponseWriter, r *http.Request) {
		handleListSatellites(w, r, cfg)
	})
	mux.HandleFunc("DELETE /api/v1/proxy/satellites/{name}", func(w http.ResponseWriter, r *http.Request) {
		handleDeleteSatellite(w, r, cfg)
	})
	if cfg.Write && cfg.ProxyEnrollSecret != "" {
		mux.HandleFunc("POST /api/v1/enroll", func(w http.ResponseWriter, r *http.Request) {
			handleEnroll(w, r, cfg)
		})
	}
}

// handleEnroll implements the server side of the enrollment handshake
// internal/enroll's client (agentic-mcpd register) already speaks: a
// caller trades a shared enroll_secret for this proxy's own public key
// (see tlsauth.PublicKeyPEMFromCertFile — the identity that will actually
// poll it going forward) and, in the same call, is added as a satellite
// this proxy now actively polls (see fleet.Manager.Enroll). Authenticated
// purely by the shared secret in the body — no bearer token exists yet at
// bootstrap time, the same reasoning /api/v1/auth/login already follows.
func handleEnroll(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	var req enroll.Request
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Errorf("decoding JSON body: %w", err))
		return
	}
	if subtle.ConstantTimeCompare([]byte(req.EnrollSecret), []byte(cfg.ProxyEnrollSecret)) != 1 {
		writeError(w, http.StatusUnauthorized, fmt.Errorf("invalid enroll_secret"))
		return
	}
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, fmt.Errorf("name must not be empty"))
		return
	}
	if req.Address == "" {
		writeError(w, http.StatusBadRequest, fmt.Errorf("address is required to register as a satellite"))
		return
	}
	if req.Token == "" {
		writeError(w, http.StatusBadRequest, fmt.Errorf("token is required to register as a satellite"))
		return
	}

	sat := config.Satellite{Name: req.Name, Address: req.Address, Token: req.Token}
	if err := cfg.SatelliteManager.Enroll(r.Context(), sat); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}

	writeJSON(w, http.StatusOK, enroll.Response{
		BossmanPublicKey: string(cfg.ProxyPublicKeyPEM),
		AgentID:          req.Name,
	})
}

func handleListSatellites(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	sats, err := cfg.SatelliteManager.List(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"satellites": sats})
}

func handleDeleteSatellite(w http.ResponseWriter, r *http.Request, cfg RESTConfig) {
	if !cfg.Write {
		writeError(w, http.StatusForbidden, fmt.Errorf("removing a satellite requires write=true"))
		return
	}
	name := r.PathValue("name")
	if err := cfg.SatelliteManager.Remove(r.Context(), name); err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"name": name, "removed": true})
}
