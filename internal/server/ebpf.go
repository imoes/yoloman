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

// DiskIOInput is the input schema for the disk_io tool.
type DiskIOInput struct {
	Limit int `json:"limit,omitempty"`
}

// SlowDiskIOInput is the input schema for the slow_disk_io tool.
type SlowDiskIOInput struct {
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

// DiskIOOutput is the output schema for the disk_io tool.
type DiskIOOutput struct {
	DiskIO []ebpf.DiskIOEvent `json:"disk_io"`
}

// SlowDiskIOOutput is the output schema for the slow_disk_io tool.
type SlowDiskIOOutput struct {
	DiskIO []ebpf.DiskIOEvent `json:"disk_io"`
}

// RegisterEBPF exposes the eBPF collector's observability data as MCP
// tools: net_connections (recent TCP state transitions), top_talkers
// (aggregated by process+remote address), exec_events (recent process
// execs), disk_io (recent completed block I/O requests with latency), and
// slow_disk_io (the slowest recent requests). Always read-only, registered
// regardless of the write gate.
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

	mcp.AddTool(s, &mcp.Tool{
		Name: "disk_io",
		Description: "" +
			"List recently completed block I/O requests on this host with their latency, " +
			"captured live via eBPF on the block:block_rq_issue/block:block_rq_complete " +
			"tracepoints (a request's issue and completion are correlated in-kernel by device+" +
			"sector). Fields: comm (issuing process), dev (raw kernel dev_t — major = dev>>20, " +
			"minor = dev&0xFFFFF), sector, nr_sector, latency_ns, rwbs (raw blktrace flag string, " +
			"e.g. \"R\"/\"WS\"/\"RA\"), and error (non-zero on I/O failure). A request seen mid-" +
			"flight when the collector attached (issue missed) is silently skipped rather than " +
			"reported with a guessed latency. Returns the most recent entries (newest last); " +
			"optionally limit how many.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "description": "Max number of recent events to return (0 or omitted = all retained)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in DiskIOInput) (*mcp.CallToolResult, DiskIOOutput, error) {
		return nil, DiskIOOutput{DiskIO: c.RecentDiskIO(in.Limit)}, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name: "slow_disk_io",
		Description: "" +
			"The slowest recently completed block I/O requests on this host, from the same " +
			"eBPF-observed data as disk_io, sorted by latency descending — useful for quickly " +
			"spotting a disk-latency spike or a specific slow request without scanning the full " +
			"recent list.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "description": "Max number of slowest events to return (0 or omitted = all retained)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in SlowDiskIOInput) (*mcp.CallToolResult, SlowDiskIOOutput, error) {
		return nil, SlowDiskIOOutput{DiskIO: c.SlowestDiskIO(in.Limit)}, nil
	})
}

// RegisterEBPFRoutes adds the REST equivalents of RegisterEBPF's tools onto
// mux: GET /api/v1/net/connections, /api/v1/net/top-talkers,
// /api/v1/exec-events, /api/v1/disk-io, /api/v1/disk-io/slowest. No-ops
// (routes are simply absent) if c is nil — callers should check ebpf
// availability before mounting.
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
	mux.HandleFunc("GET /api/v1/disk-io", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"disk_io": c.RecentDiskIO(limitParam(r))})
	})
	mux.HandleFunc("GET /api/v1/disk-io/slowest", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"disk_io": c.SlowestDiskIO(limitParam(r))})
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
