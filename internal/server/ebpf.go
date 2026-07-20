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

// OOMKillsInput/Output — recent OOM-kill victims (BCC oomkill).
type OOMKillsInput struct {
	Limit int `json:"limit,omitempty"`
}
type OOMKillsOutput struct {
	OOMKills []ebpf.OOMKillEvent `json:"oom_kills"`
}

// TCPRetransmitsInput/Output — recent TCP retransmissions (BCC tcpretrans).
type TCPRetransmitsInput struct {
	Limit int `json:"limit,omitempty"`
}
type TCPRetransmitsOutput struct {
	Retransmits []ebpf.TCPRetransEvent `json:"retransmits"`
}

// SignalsInput/Output — recent notable signal deliveries (BCC killsnoop).
type SignalsInput struct {
	Limit int `json:"limit,omitempty"`
}
type SignalsOutput struct {
	Signals []ebpf.SignalEvent `json:"signals"`
}

// RunqLatencyInput/Output — run-queue-latency histogram (BCC runqlat).
type RunqLatencyInput struct{}
type RunqLatencyOutput struct {
	Histogram []ebpf.RunqBucket `json:"histogram"`
}

// L7RequestsInput/Output — recent passive L7 exchanges (Tier-2).
type L7RequestsInput struct {
	Protocol string `json:"protocol,omitempty"`
	Limit    int    `json:"limit,omitempty"`
}
type L7RequestsOutput struct {
	Events []ebpf.L7Event `json:"events"`
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

	mcp.AddTool(s, &mcp.Tool{
		Name: "oom_kills",
		Description: "" +
			"List processes the kernel's OOM killer recently terminated on this host (pid + " +
			"command of each victim), captured live via eBPF on the oom:mark_victim tracepoint " +
			"— the direct answer to 'why did my service disappear?' when it was killed for memory " +
			"pressure rather than crashing. Returns the most recent entries (newest last).",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "description": "Max number of recent OOM kills to return (0 or omitted = all retained)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in OOMKillsInput) (*mcp.CallToolResult, OOMKillsOutput, error) {
		return nil, OOMKillsOutput{OOMKills: c.RecentOOMKills(in.Limit)}, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name: "tcp_retransmits",
		Description: "" +
			"List recent TCP retransmissions on this host (the affected connection's 4-tuple + " +
			"issuing process), captured live via eBPF on the tcp:tcp_retransmit_skb tracepoint. A " +
			"rising retransmit rate to a given peer is an early network-health signal (packet " +
			"loss / congestion / a struggling remote) that surfaces before connection timeouts do. " +
			"IPv4 only in v1. Returns the most recent entries (newest last).",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "description": "Max number of recent retransmits to return (0 or omitted = all retained)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in TCPRetransmitsInput) (*mcp.CallToolResult, TCPRetransmitsOutput, error) {
		return nil, TCPRetransmitsOutput{Retransmits: c.RecentTCPRetransmits(in.Limit)}, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name: "signals",
		Description: "" +
			"List recent notable signal deliveries on this host — sender (pid/comm), target " +
			"(pid/comm) and the signal (INT/QUIT/ABRT/KILL/SEGV/TERM only, filtered in-kernel to " +
			"avoid SIGCHLD/timer noise), captured live via eBPF on signal:signal_generate. " +
			"killsnoop-style: reveals who is killing a process — an external kill, an OOM handler, " +
			"or a misbehaving watchdog. Returns the most recent entries (newest last).",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "description": "Max number of recent signals to return (0 or omitted = all retained)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in SignalsInput) (*mcp.CallToolResult, SignalsOutput, error) {
		return nil, SignalsOutput{Signals: c.RecentSignals(in.Limit)}, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name: "runq_latency",
		Description: "" +
			"Run-queue latency histogram for this host (BCC runqlat): how long tasks sat runnable " +
			"waiting for a CPU before being scheduled, as a log2-microsecond distribution measured " +
			"in-kernel via eBPF on sched:sched_wakeup + sched:sched_switch. A tail extending into " +
			"the milliseconds means CPU saturation / scheduler contention — a signal 'load average' " +
			"alone doesn't give. Cumulative since the collector started.",
		InputSchema: map[string]any{"type": "object", "properties": map[string]any{}},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in RunqLatencyInput) (*mcp.CallToolResult, RunqLatencyOutput, error) {
		h, err := c.RunqLatency()
		if err != nil {
			return nil, RunqLatencyOutput{}, err
		}
		return nil, RunqLatencyOutput{Histogram: h}, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name: "l7_requests",
		Description: "" +
			"List recent application-layer (L7) request/response exchanges observed on this host, " +
			"captured passively via eBPF on the read/write/sendto/recvfrom syscall tracepoints — no " +
			"instrumentation, no ports assumed (protocol is detected by sniffing the payload). Each " +
			"exchange carries protocol (http/dns/postgres/mysql), the request (HTTP method+path / DNS " +
			"name+type / SQL text), a classified status (2xx…/5xx, ok/nxdomain/…), latency, and the " +
			"destination addr:port. Plaintext only (no TLS). Optionally filter by protocol. Newest last.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"protocol": map[string]any{"type": "string", "description": "Filter to one of http|dns|postgres|mysql (omitted = all)."},
				"limit":    map[string]any{"type": "integer", "description": "Max exchanges to return (0 or omitted = all retained)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in L7RequestsInput) (*mcp.CallToolResult, L7RequestsOutput, error) {
		return nil, L7RequestsOutput{Events: c.RecentL7(in.Protocol, in.Limit)}, nil
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
	mux.HandleFunc("GET /api/v1/oom-kills", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"oom_kills": c.RecentOOMKills(limitParam(r))})
	})
	mux.HandleFunc("GET /api/v1/tcp-retransmits", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"retransmits": c.RecentTCPRetransmits(limitParam(r))})
	})
	mux.HandleFunc("GET /api/v1/signals", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"signals": c.RecentSignals(limitParam(r))})
	})
	mux.HandleFunc("GET /api/v1/runq-latency", func(w http.ResponseWriter, r *http.Request) {
		h, err := c.RunqLatency()
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"histogram": h})
	})
	// Passive L7 (Tier-2): recent exchanges per protocol. `?protocol=` also
	// accepted on /api/v1/l7 for an all-protocols or single-protocol view.
	mux.HandleFunc("GET /api/v1/l7", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"events": c.RecentL7(r.URL.Query().Get("protocol"), limitParam(r))})
	})
	for _, proto := range []string{"http", "dns", "postgres", "mysql"} {
		p := proto
		mux.HandleFunc("GET /api/v1/l7/"+p, func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, http.StatusOK, map[string]any{"events": c.RecentL7(p, limitParam(r))})
		})
	}
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
