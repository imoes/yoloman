package main

import (
	"crypto/subtle"
	"log/slog"
	"net/http"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/webui"
)

// serveHTTP starts the Streamable HTTP MCP endpoint at /mcp (bearer-token
// only — v1 has one fixed token identity for MCP, see docs/plan.md), the
// REST API under /api/v1/ (bearer token OR a PAM-login session — REST
// authenticates itself via its own middleware, see internal/server/rest.go's
// withIdentity, so it is mounted here without an additional auth wrapper),
// the static admin UI under /ui/ (public static assets; the page itself
// authenticates against /api/v1/ once loaded), and an unauthenticated
// /healthz.
func serveHTTP(cfg config.Config, mcpServer *mcp.Server, restHandler http.Handler) error {
	mcpHandler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server {
		return mcpServer
	}, nil)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.Handle("/mcp", withBearerAuth(cfg.Token, mcpHandler))
	mux.Handle("/api/v1/", restHandler)

	if cfg.UI.Enabled {
		uiHandler, err := webui.Handler("/ui")
		if err != nil {
			return err
		}
		mux.Handle("/ui/", uiHandler)
	}

	if cfg.TLS.Enabled {
		slog.Info("agentic-mcpd listening (TLS)", "addr", cfg.Listen)
		return http.ListenAndServeTLS(cfg.Listen, cfg.TLS.CertFile, cfg.TLS.KeyFile, mux)
	}
	slog.Info("agentic-mcpd listening", "addr", cfg.Listen)
	return http.ListenAndServe(cfg.Listen, mux)
}

// withBearerAuth wraps h with bearer-token authentication using a
// constant-time comparison. If token is empty, auth is disabled (intended
// only for local/dev use — the packaged config always has a generated token).
func withBearerAuth(token string, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if token == "" {
			h.ServeHTTP(w, r)
			return
		}
		const prefix = "Bearer "
		auth := r.Header.Get("Authorization")
		if len(auth) < len(prefix) || auth[:len(prefix)] != prefix {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		given := auth[len(prefix):]
		if subtle.ConstantTimeCompare([]byte(given), []byte(token)) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		h.ServeHTTP(w, r)
	})
}
