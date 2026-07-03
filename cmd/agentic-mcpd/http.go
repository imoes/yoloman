package main

import (
	"crypto/subtle"
	"crypto/tls"
	"log/slog"
	"net/http"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/tlsauth"
	"github.com/mutkluge/agentic-mcp/internal/webui"
)

// serveHTTP starts the Streamable HTTP MCP endpoint at /mcp (bearer-token
// only — v1 has one fixed token identity for MCP, see docs/plan.md), the
// REST API under /api/v1/ (bearer token OR a PAM-login session — REST
// authenticates itself via its own middleware, see internal/server/rest.go's
// withIdentity, so it is mounted here without an additional auth wrapper),
// the static admin UI under /ui/ (public static assets; the page itself
// authenticates against /api/v1/ once loaded), and an unauthenticated
// /healthz. When cfg.TLS.TrustedClientKeys is configured, /mcp and
// /api/v1/ additionally require a matching TLS client certificate — see
// requireTrustedClientCert.
func serveHTTP(cfg config.Config, mcpServer *mcp.Server, restHandler http.Handler) error {
	mcpHandler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server {
		return mcpServer
	}, nil)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mcpFinal := withBearerAuth(cfg.Token, mcpHandler)
	restFinal := restHandler
	if len(cfg.TLS.TrustedClientKeys) > 0 {
		trusted := loadTrustedClientKeys(cfg.TLS.TrustedClientKeys)
		mcpFinal = requireTrustedClientCert(trusted, mcpFinal)
		restFinal = requireTrustedClientCert(trusted, restFinal)
	}
	mux.Handle("/mcp", mcpFinal)
	mux.Handle("/api/v1/", restFinal)

	if cfg.UI.Enabled {
		uiHandler, err := webui.Handler("/ui")
		if err != nil {
			return err
		}
		mux.Handle("/ui/", uiHandler)
	}

	if cfg.TLS.Enabled {
		srv := &http.Server{Addr: cfg.Listen, Handler: mux}
		if len(cfg.TLS.TrustedClientKeys) > 0 {
			// Requested, not required, at the transport level: PAM-login
			// browser access to /ui/ must keep working without a client
			// certificate. requireTrustedClientCert enforces the actual
			// requirement, scoped to /mcp and /api/v1/ only.
			srv.TLSConfig = &tls.Config{ClientAuth: tls.RequestClientCert}
		}
		slog.Info("agentic-mcpd listening (TLS)", "addr", cfg.Listen)
		return srv.ListenAndServeTLS(cfg.TLS.CertFile, cfg.TLS.KeyFile)
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

// loadTrustedClientKeys resolves each configured trusted_client_keys entry
// to its DER-encoded public key, skipping (and logging) any that fail to
// load — graceful degradation consistent with the rest of the daemon: a
// broken entry never matches, it doesn't crash the server.
func loadTrustedClientKeys(keys []config.TrustedClientKey) []tlsauth.TrustedKey {
	var out []tlsauth.TrustedKey
	for _, k := range keys {
		tk, err := tlsauth.LoadTrustedKey(k.Name, k.PublicKeyPath)
		if err != nil {
			slog.Error("failed to load tls.trusted_client_keys entry, it will never match", "name", k.Name, "error", err)
			continue
		}
		out = append(out, tk)
	}
	return out
}

// requireTrustedClientCert wraps h so that every request must present a TLS
// client certificate matching one of trusted (see internal/tlsauth) before
// reaching h — the authorization gate for machine callers (a Fleet
// Commander or a proxy), checked in addition to whatever auth h itself
// performs (bearer token, PAM session, ...).
func requireTrustedClientCert(trusted []tlsauth.TrustedKey, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
			http.Error(w, "client certificate required", http.StatusUnauthorized)
			return
		}
		if _, ok := tlsauth.MatchesAny(r.TLS.PeerCertificates[0], trusted); !ok {
			http.Error(w, "client certificate not trusted", http.StatusUnauthorized)
			return
		}
		h.ServeHTTP(w, r)
	})
}
