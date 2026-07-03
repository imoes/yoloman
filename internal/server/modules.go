package server

import (
	"context"
	"fmt"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/modules"
)

// NewDefaultModuleRegistry returns a registry populated with all of v1's
// read/facts modules (setup, stat, find, slurp, service_facts,
// package_facts, getent). Write modules are added in a later step, gated by
// config.Write.
func NewDefaultModuleRegistry() *modules.Registry {
	reg := modules.NewRegistry()
	for _, m := range []modules.Module{
		modules.NewSetup(),
		modules.NewStat(),
		modules.NewFind(),
		modules.NewSlurp(),
		modules.NewServiceFacts(),
		modules.NewPackageFacts(),
		modules.NewGetent(),
	} {
		if err := reg.Register(m); err != nil {
			// Registration only fails on a duplicate name among modules
			// defined in this same file, i.e. a programming error.
			panic(fmt.Sprintf("registering built-in module: %v", err))
		}
	}
	return reg
}

// RegisterModules exposes every module in reg as an MCP tool. Read-only
// modules (Writes() == false) are always registered; writing modules are
// only registered when write is true — the write gate.
func RegisterModules(s *mcp.Server, reg *modules.Registry, write bool) {
	for _, m := range reg.All() {
		if m.Writes() && !write {
			continue
		}
		registerModuleTool(s, m)
	}
}

// moduleResultOutputSchema is used instead of the schema auto-inferred from
// modules.Result, whose Data field is `any`. The Go jsonschema-go inferrer
// renders an `any` field as the bare boolean schema `true` ("matches
// anything"), which is valid JSON Schema but not accepted by every client's
// schema validator (observed with the MCP Inspector CLI). An empty object
// schema `{}` means the same thing and is far more broadly compatible —
// important here since the whole point is working with many different
// orchestrators/clients, not just one.
var moduleResultOutputSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"changed": map[string]any{"type": "boolean"},
		"msg":     map[string]any{"type": "string"},
		"data":    map[string]any{},
	},
	"required": []string{"changed"},
}

func registerModuleTool(s *mcp.Server, m modules.Module) {
	mcp.AddTool(s, &mcp.Tool{
		Name:         m.Name(),
		Description:  m.Description(),
		InputSchema:  m.InputSchema(),
		OutputSchema: moduleResultOutputSchema,
	}, func(ctx context.Context, req *mcp.CallToolRequest, in map[string]any) (*mcp.CallToolResult, modules.Result, error) {
		res, err := m.Run(ctx, in, false)
		if err != nil {
			return nil, modules.Result{}, err
		}
		return nil, res, nil
	})
}
