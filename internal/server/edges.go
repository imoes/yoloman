package server

import (
	"fmt"
	"net/http"
	"time"

	"github.com/mutkluge/agentic-mcp/internal/store"
)

// ConnectionEdge is one JSON-friendly persisted connection edge — the
// GET /api/v1/net/connections/dump response shape.
type ConnectionEdge struct {
	Comm       string `json:"comm"`
	DstAddr    string `json:"dst_addr"`
	DstPort    uint16 `json:"dst_port"`
	EventCount int64  `json:"event_count"`
	FirstSeen  string `json:"first_seen"`
	LastSeen   string `json:"last_seen"`
	LatencyNs  *int64 `json:"latency_ns,omitempty"`
}

// RegisterConnectionsDumpRoute adds GET /api/v1/net/connections/dump?since=
// — the durable, cursor-based counterpart to the live in-memory
// net_connections MCP tool/REST route: a bulk dump of every persisted
// connection edge last seen at or after `since` (RFC3339 timestamp or a Go
// duration like "1h", default 24h), for a caller that wants only what
// changed since its last successful pull instead of polling a bounded
// in-memory ring buffer (see docs/plan.md's Bossman "v3" Block A).
// Deliberately REST-only, no MCP tool equivalent: this data is meant for
// machine-to-machine fleet polling (a proxy, or the future Bossman), not
// for an AI to call directly — an AI already has net_connections/
// top_talkers for the live view. No-op (route absent) if st is nil.
func RegisterConnectionsDumpRoute(mux *http.ServeMux, st store.Store) {
	if st == nil {
		return
	}
	mux.HandleFunc("GET /api/v1/net/connections/dump", func(w http.ResponseWriter, r *http.Request) {
		since, err := parseTimeBound(r.URL.Query().Get("since"), time.Now(), -24*time.Hour)
		if err != nil {
			writeError(w, http.StatusBadRequest, fmt.Errorf("since: %w", err))
			return
		}
		edges, err := st.ListEdgesSince(r.Context(), since)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		out := make([]ConnectionEdge, len(edges))
		for i, e := range edges {
			out[i] = ConnectionEdge{
				Comm:       e.Comm,
				DstAddr:    e.DstAddr,
				DstPort:    e.DstPort,
				EventCount: e.EventCount,
				FirstSeen:  e.FirstSeen.Format(time.RFC3339),
				LastSeen:   e.LastSeen.Format(time.RFC3339),
				LatencyNs:  e.LatencyNs,
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{"edges": out})
	})
}
