package server

import (
	"context"
	"net/http"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/ebpf"
)

// NetConnectionsInput is the input schema for the net_connections tool.
type NetConnectionsInput struct {
	Limit int `json:"limit,omitempty"`
}

// TopTalkersInput is the input schema for the top_talkers tool.
type TopTalkersInput struct {
	Limit int `json:"limit,omitempty"`
}

// ExecEventsInput is the input schema for the exec_events tool.
type ExecEventsInput struct {
	Limit int `json:"limit,omitempty"`
}

// NetConnectionsOutput is the output schema for the net_connections tool.
type NetConnectionsOutput struct {
	Connections []ebpf.TCPConnEvent `json:"connections"`
}

// TopTalkersOutput is the output schema for the top_talkers tool.
type TopTalkersOutput struct {
	TopTalkers []ebpf.TopTalker `json:"top_talkers"`
}

// ExecEventsOutput is the output schema for the exec_events tool.
type ExecEventsOutput struct {
	ExecEvents []ebpf.ExecEvent `json:"exec_events"`
}

// RegisterEBPF exposes the eBPF collector's observability data as MCP
// tools: net_connections (recent TCP state transitions), top_talkers
// (aggregated by process+remote address), and exec_events (recent process
// execs). Always read-only, registered regardless of the write gate.
func RegisterEBPF(s *mcp.Server, c *ebpf.Collector) {
	mcp.AddTool(s, &mcp.Tool{
		Name: "net_connections",
		Description: "" +
			"List recently observed TCP connection state transitions on this host (both " +
			"outbound connect() completions and inbound accept() completions surface here), " +
			"captured live via eBPF — process, local/remote address:port, and the old/new TCP " +
			"state (e.g. SYN_SENT -> ESTABLISHED, ESTABLISHED -> TIME_WAIT). This is the " +
			"foundation for a Coroot-style service map: who talks to whom, in near real time, " +
			"without a sidecar per process. IPv4 only in v1. Returns the most recent entries " +
			"(newest last); optionally limit how many.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "description": "Max number of recent events to return (0 or omitted = all retained)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in NetConnectionsInput) (*mcp.CallToolResult, NetConnectionsOutput, error) {
		return nil, NetConnectionsOutput{Connections: c.RecentConns(in.Limit)}, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name: "top_talkers",
		Description: "" +
			"Summarize which processes are establishing the most TCP connections to which " +
			"remote endpoints, aggregated from the same eBPF-observed data as net_connections " +
			"(counts only ESTABLISHED transitions). Useful for spotting a chatty process or an " +
			"unexpected remote endpoint at a glance, without wading through the raw connection " +
			"list. Returns entries sorted by connection count, descending.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "description": "Max number of talkers to return (0 or omitted = all)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in TopTalkersInput) (*mcp.CallToolResult, TopTalkersOutput, error) {
		return nil, TopTalkersOutput{TopTalkers: c.TopTalkers(in.Limit)}, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name: "exec_events",
		Description: "" +
			"List recently observed process executions on this host (pid, command, and the " +
			"full path that was executed), captured live via eBPF on the kernel's " +
			"sched_process_exec tracepoint — this sees every exec, not just ones spawned by a " +
			"particular supervisor, giving a lightweight 'what's running / what just ran' view " +
			"useful for incident investigation or noticing unexpected processes. Returns the " +
			"most recent entries (newest last); optionally limit how many.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "description": "Max number of recent events to return (0 or omitted = all retained)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in ExecEventsInput) (*mcp.CallToolResult, ExecEventsOutput, error) {
		return nil, ExecEventsOutput{ExecEvents: c.RecentExecs(in.Limit)}, nil
	})
}

// RegisterEBPFRoutes adds the REST equivalents of RegisterEBPF's tools onto
// mux: GET /api/v1/net/connections, /api/v1/net/top-talkers,
// /api/v1/exec-events. No-ops (routes are simply absent) if c is nil —
// callers should check ebpf availability before mounting.
func RegisterEBPFRoutes(mux *http.ServeMux, c *ebpf.Collector) {
	if c == nil {
		return
	}
	mux.HandleFunc("GET /api/v1/net/connections", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"connections": c.RecentConns(limitParam(r))})
	})
	mux.HandleFunc("GET /api/v1/net/top-talkers", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"top_talkers": c.TopTalkers(limitParam(r))})
	})
	mux.HandleFunc("GET /api/v1/exec-events", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"exec_events": c.RecentExecs(limitParam(r))})
	})
}

func limitParam(r *http.Request) int {
	v := r.URL.Query().Get("limit")
	if v == "" {
		return 0
	}
	n := 0
	for _, ch := range v {
		if ch < '0' || ch > '9' {
			return 0
		}
		n = n*10 + int(ch-'0')
	}
	return n
}
