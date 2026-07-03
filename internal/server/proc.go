// Package server wires agentic-mcp's internal packages (proc, modules, tools,
// ...) onto an MCP server as resources and tools.
package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/proc"
)

// procResource describes one /proc file exposed as a read-only MCP resource
// whose contents are parsed into structured JSON rather than returned raw.
type procResource struct {
	uri, name, description, relPath string
}

// RegisterProc registers /proc-derived MCP resources (parsed to JSON) and the
// generic proc_read tool (path-guarded raw read) on s, sourcing data from
// procRoot (normally "/proc").
func RegisterProc(s *mcp.Server, procRoot string) {
	addJSONResource(s, procRoot, procResource{
		uri: "proc://meminfo", name: "meminfo",
		description: "Parsed /proc/meminfo (memory sizes in kB)", relPath: "meminfo",
	}, proc.ParseMemInfo)

	addJSONResource(s, procRoot, procResource{
		uri: "proc://loadavg", name: "loadavg",
		description: "Parsed /proc/loadavg (1/5/15 min load averages)", relPath: "loadavg",
	}, proc.ParseLoadAvg)

	addJSONResource(s, procRoot, procResource{
		uri: "proc://uptime", name: "uptime",
		description: "Parsed /proc/uptime (system + idle seconds)", relPath: "uptime",
	}, proc.ParseUptime)

	addJSONResource(s, procRoot, procResource{
		uri: "proc://cpuinfo", name: "cpuinfo",
		description: "Parsed /proc/cpuinfo (one entry per logical CPU)", relPath: "cpuinfo",
	}, proc.ParseCPUInfo)

	addJSONResource(s, procRoot, procResource{
		uri: "proc://mounts", name: "mounts",
		description: "Parsed /proc/mounts (device, mount point, fs type, options)", relPath: "mounts",
	}, proc.ParseMounts)

	addJSONResource(s, procRoot, procResource{
		uri: "proc://net/dev", name: "net_dev",
		description: "Parsed /proc/net/dev (per-interface rx/tx counters)", relPath: "net/dev",
	}, proc.ParseNetDev)

	addJSONResource(s, procRoot, procResource{
		uri: "proc://diskstats", name: "diskstats",
		description: "Parsed /proc/diskstats (per-device I/O counters)", relPath: "diskstats",
	}, proc.ParseDiskStats)

	registerProcRead(s, procRoot)
}

// addJSONResource registers a resource that reads relPath under procRoot,
// parses it with parse, and returns the result as pretty-printed JSON text.
func addJSONResource[T any](s *mcp.Server, procRoot string, r procResource, parse func(io.Reader) (T, error)) {
	s.AddResource(&mcp.Resource{
		URI:         r.uri,
		Name:        r.name,
		Description: r.description,
		MIMEType:    "application/json",
	}, func(ctx context.Context, req *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
		f, err := os.Open(filepath.Join(procRoot, r.relPath))
		if err != nil {
			return nil, fmt.Errorf("opening %s: %w", r.relPath, err)
		}
		defer f.Close()

		val, err := parse(f)
		if err != nil {
			return nil, fmt.Errorf("parsing %s: %w", r.relPath, err)
		}
		data, err := json.MarshalIndent(val, "", "  ")
		if err != nil {
			return nil, fmt.Errorf("marshaling %s: %w", r.relPath, err)
		}
		return &mcp.ReadResourceResult{
			Contents: []*mcp.ResourceContents{{
				URI:      req.Params.URI,
				MIMEType: "application/json",
				Text:     string(data),
			}},
		}, nil
	})
}

// ProcReadInput is the input schema for the proc_read tool.
type ProcReadInput struct {
	Path string `json:"path" jsonschema:"path under /proc to read, e.g. 'self/status' or 'meminfo'"`
}

// ProcReadOutput is the output schema for the proc_read tool.
type ProcReadOutput struct {
	Content string `json:"content"`
}

// registerProcRead adds a generic, path-guarded raw-read tool for /proc
// entries that have no dedicated parser above (e.g. /proc/<pid>/status).
// It refuses to follow paths that escape procRoot, see proc.SafeRead.
func registerProcRead(s *mcp.Server, procRoot string) {
	mcp.AddTool(s, &mcp.Tool{
		Name:        "proc_read",
		Description: "Read a file under /proc as raw text. Rejects paths that escape /proc (e.g. via '..' or symlinks like <pid>/exe, <pid>/cwd).",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in ProcReadInput) (*mcp.CallToolResult, ProcReadOutput, error) {
		data, err := proc.SafeRead(procRoot, in.Path, 0)
		if err != nil {
			return nil, ProcReadOutput{}, err
		}
		return nil, ProcReadOutput{Content: string(data)}, nil
	})
}
