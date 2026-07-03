package main

import (
	"crypto/subtle"
	"log/slog"
	"net/http"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/config"
)

// serveHTTP starts the Streamable HTTP MCP endpoint at /mcp, guarded by
// bearer-token auth when cfg.Token is set, plus an unauthenticated /healthz.
func serveHTTP(cfg config.Config, server *mcp.Server) error {
	mcpHandler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server {
		return server
	}, nil)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.Handle("/mcp", withBearerAuth(cfg.Token, mcpHandler))

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
