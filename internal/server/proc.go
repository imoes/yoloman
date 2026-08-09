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

// procResourceDef describes one /proc file exposed both as a read-only MCP
// resource and (rendered through the same render func) as a REST endpoint —
// parsed into structured JSON rather than returned raw.
type procResourceDef struct {
	uri, name, description string
	render                 func(procRoot string) ([]byte, error)
}

// newProcResourceDef builds a procResourceDef that opens relPath under a
// given procRoot, parses it with parse, and renders the result as
// pretty-printed JSON — shared by both the MCP resource handler and the
// REST /api/v1/proc/{name} handler.
func newProcResourceDef[T any](uri, name, description, relPath string, parse func(io.Reader) (T, error)) procResourceDef {
	return procResourceDef{
		uri: uri, name: name, description: description,
		render: func(procRoot string) ([]byte, error) {
			f, err := os.Open(filepath.Join(procRoot, relPath))
			if err != nil {
				return nil, fmt.Errorf("opening %s: %w", relPath, err)
			}
			defer f.Close()

			val, err := parse(f)
			if err != nil {
				return nil, fmt.Errorf("parsing %s: %w", relPath, err)
			}
			return json.MarshalIndent(val, "", "  ")
		},
	}
}

// procResourceDefs is the fixed set of /proc files with a dedicated parser.
var procResourceDefs = []procResourceDef{
	newProcResourceDef("proc://meminfo", "meminfo",
		"Parsed /proc/meminfo (memory sizes in kB)", "meminfo", proc.ParseMemInfo),
	newProcResourceDef("proc://loadavg", "loadavg",
		"Parsed /proc/loadavg (1/5/15 min load averages)", "loadavg", proc.ParseLoadAvg),
	newProcResourceDef("proc://uptime", "uptime",
		"Parsed /proc/uptime (system + idle seconds)", "uptime", proc.ParseUptime),
	newProcResourceDef("proc://cpuinfo", "cpuinfo",
		"Parsed /proc/cpuinfo (one entry per logical CPU)", "cpuinfo", proc.ParseCPUInfo),
	newProcResourceDef("proc://mounts", "mounts",
		"Parsed /proc/mounts (device, mount point, fs type, options)", "mounts", proc.ParseMounts),
	newProcResourceDef("proc://net/dev", "net_dev",
		"Parsed /proc/net/dev (per-interface rx/tx counters)", "net/dev", proc.ParseNetDev),
	newProcResourceDef("proc://diskstats", "diskstats",
		"Parsed /proc/diskstats (per-device I/O counters)", "diskstats", proc.ParseDiskStats),
}

// RegisterProc registers /proc-derived MCP resources (parsed to JSON) and the
// generic proc_read tool (path-guarded raw read) on s, sourcing data from
// procRoot (normally "/proc").
func RegisterProc(s *mcp.Server, procRoot string) {
	for _, def := range procResourceDefs {
		def := def
		s.AddResource(&mcp.Resource{
			URI:         def.uri,
			Name:        def.name,
			Description: def.description,
			MIMEType:    "application/json",
		}, func(ctx context.Context, req *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
			data, err := def.render(procRoot)
			if err != nil {
				return nil, err
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
	registerProcRead(s, procRoot)
}

// RenderProcResource renders the named proc resource (its short name, e.g.
// "meminfo") as JSON, for the REST layer. ok is false if name is not a known
// proc resource.
func RenderProcResource(procRoot, name string) (data []byte, ok bool, err error) {
	for _, def := range procResourceDefs {
		if def.name == name {
			data, err = def.render(procRoot)
			return data, true, err
		}
	}
	return nil, false, nil
}

// ProcResourceNames returns the short names of every available proc
// resource, for REST discoverability.
func ProcResourceNames() []string {
	names := make([]string, len(procResourceDefs))
	for i, d := range procResourceDefs {
		names[i] = d.name
	}
	return names
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
