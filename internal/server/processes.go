package server

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/ebpf"
	"github.com/mutkluge/agentic-mcp/internal/proc"
)

// processSampleWindow is how long the process endpoint samples CPU ticks
// before computing each process' CPU%. Short enough that the request stays
// snappy, long enough that the delta is meaningful.
const processSampleWindow = 200 * time.Millisecond

// ProcessConn is one eBPF-observed outbound endpoint a process is talking to
// (deduplicated by dst:port), the "who talks to whom" enrichment on top of
// the /proc view (Block J1).
type ProcessConn struct {
	DstAddr string `json:"dst_addr"`
	DstPort uint16 `json:"dst_port"`
	State   string `json:"state"`
}

// ProcessView is a /proc process row plus the optional eBPF enrichment the
// server layer can attach (this package owns the collector; internal/proc
// deliberately does not depend on it).
type ProcessView struct {
	proc.Process
	ContainerID string        `json:"container_id,omitempty"`
	Connections []ProcessConn `json:"connections,omitempty"`
}

// ProcessesResponse is the GET /api/v1/processes / process_list payload.
type ProcessesResponse struct {
	Processes      []ProcessView `json:"processes"`
	Count          int           `json:"count"`
	SampleWindowMS int64         `json:"sample_window_ms"`
}

// collectProcesses samples the process table and, when an eBPF collector is
// available, enriches each process with its container id and recent outbound
// connections. limit (>0) keeps only the top-N by the enumerator's default
// CPU-descending order; Count still reports the true total.
func collectProcesses(procRoot string, c *ebpf.Collector, limit int) (ProcessesResponse, error) {
	procs, err := proc.SampleProcesses(procRoot, processSampleWindow)
	if err != nil {
		return ProcessesResponse{}, err
	}

	var containerByPID map[int]string
	var connsByPID map[int][]ProcessConn
	if c != nil {
		containerByPID = execContainerByPID(c.RecentExecs(0))
		connsByPID = establishedConnsByPID(c.RecentConns(0))
	}

	total := len(procs)
	if limit > 0 && limit < total {
		procs = procs[:limit]
	}
	views := make([]ProcessView, 0, len(procs))
	for _, p := range procs {
		v := ProcessView{Process: p}
		if containerByPID != nil {
			v.ContainerID = containerByPID[p.PID]
			v.Connections = connsByPID[p.PID]
		}
		views = append(views, v)
	}
	return ProcessesResponse{
		Processes:      views,
		Count:          total,
		SampleWindowMS: processSampleWindow.Milliseconds(),
	}, nil
}

// execContainerByPID maps pid → container id from recent exec events. Events
// are newest-last, so a later exec for a reused pid correctly overwrites an
// earlier one.
func execContainerByPID(execs []ebpf.ExecEvent) map[int]string {
	m := make(map[int]string, len(execs))
	for _, e := range execs {
		if e.ContainerID != "" {
			m[int(e.PID)] = e.ContainerID
		}
	}
	return m
}

// establishedConnsByPID groups recent ESTABLISHED connections by pid,
// deduplicated by remote endpoint so a chatty process doesn't produce a
// hundred identical rows.
func establishedConnsByPID(conns []ebpf.TCPConnEvent) map[int][]ProcessConn {
	m := map[int][]ProcessConn{}
	seen := map[int]map[string]bool{}
	for _, c := range conns {
		if c.NewState != "ESTABLISHED" {
			continue
		}
		pid := int(c.PID)
		key := c.DstAddr + ":" + strconv.Itoa(int(c.DstPort))
		if seen[pid] == nil {
			seen[pid] = map[string]bool{}
		}
		if seen[pid][key] {
			continue
		}
		seen[pid][key] = true
		m[pid] = append(m[pid], ProcessConn{DstAddr: c.DstAddr, DstPort: c.DstPort, State: c.NewState})
	}
	return m
}

// RegisterProcessRoutes mounts GET /api/v1/processes. Unlike the eBPF routes
// this is mounted even without a collector (the /proc process list stands on
// its own; eBPF only adds the container/connection enrichment).
func RegisterProcessRoutes(mux *http.ServeMux, cfg RESTConfig) {
	mux.HandleFunc("GET /api/v1/processes", func(w http.ResponseWriter, r *http.Request) {
		resp, err := collectProcesses(cfg.ProcRoot, cfg.EBPF, limitParam(r))
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		writeJSON(w, http.StatusOK, resp)
	})
}

// ProcessListInput is the input schema for the process_list MCP tool.
type ProcessListInput struct {
	Limit int `json:"limit,omitempty"`
}

// RegisterProcessList exposes the process table as the read-only process_list
// MCP tool, mirroring GET /api/v1/processes. procRoot is normally "/proc"; c
// may be nil (enrichment omitted).
func RegisterProcessList(s *mcp.Server, procRoot string, c *ebpf.Collector) {
	mcp.AddTool(s, &mcp.Tool{
		Name: "process_list",
		Description: "" +
			"List the processes running on this host — the 'identify the resource hog' view. " +
			"For each process: pid, ppid, owning user, command line, state, CPU% (sampled over a " +
			"short window; 100% == one core, so a busy multi-threaded process can exceed 100%), " +
			"resident memory (rss_kib) and thread count. Sorted hungriest-first (CPU descending, " +
			"then memory). When eBPF is available each process is enriched with its container id " +
			"and the remote endpoints it is talking to (from the same live TCP tracking as " +
			"net_connections). Read-only. Optionally limit to the top-N.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"limit": map[string]any{"type": "integer", "description": "Keep only the top-N hungriest processes (0 or omitted = all)."},
			},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in ProcessListInput) (*mcp.CallToolResult, ProcessesResponse, error) {
		resp, err := collectProcesses(procRoot, c, in.Limit)
		if err != nil {
			return nil, ProcessesResponse{}, err
		}
		return nil, resp, nil
	})
}
