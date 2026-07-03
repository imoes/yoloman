package server

import (
	"context"
	"fmt"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/authz"
	"github.com/mutkluge/agentic-mcp/internal/modules"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/tasks"
)

// RegisterTasks exposes every task in list as a curated MCP tool, dispatching
// to modReg (for module tasks) or via policy (for pipeline tasks). Tasks
// whose underlying operation writes are only registered when write is true —
// the same write gate used for built-in modules. acl may be nil (see
// RegisterModules).
func RegisterTasks(s *mcp.Server, list []*tasks.Task, modReg *modules.Registry, policy *pipeline.Policy, write bool, acl *authz.ACL) error {
	for _, task := range list {
		writes, err := task.Writes(modReg)
		if err != nil {
			return fmt.Errorf("registering task %q: %w", task.Name, err)
		}
		if writes && !write {
			continue
		}
		registerTaskTool(s, task, modReg, policy, acl)
	}
	return nil
}

func registerTaskTool(s *mcp.Server, task *tasks.Task, modReg *modules.Registry, policy *pipeline.Policy, acl *authz.ACL) {
	mcp.AddTool(s, &mcp.Tool{
		Name:         task.Name,
		Description:  task.Description,
		InputSchema:  task.InputSchema(),
		OutputSchema: moduleResultOutputSchema,
	}, func(ctx context.Context, req *mcp.CallToolRequest, in map[string]any) (*mcp.CallToolResult, modules.Result, error) {
		writes, err := task.Writes(modReg)
		if err != nil {
			return nil, modules.Result{}, err
		}
		if err := checkACL(ctx, acl, task.Name, writes); err != nil {
			return nil, modules.Result{}, err
		}
		res, err := task.Run(ctx, modReg, policy, in, false)
		if err != nil {
			return nil, modules.Result{}, err
		}
		return nil, res, nil
	})
}

// RunPipelineInput is the input schema for the ad-hoc run_pipeline tool.
type RunPipelineInput struct {
	Stages [][]string `json:"stages" jsonschema:"argv stages to chain, e.g. [[\"ps\",\"aux\"],[\"grep\",\"nginx\"]]; each stage's binary must be in the configured command policy"`
}

// RegisterRunPipeline adds the ad-hoc run_pipeline tool, letting a caller
// chain whitelisted commands (per policy) without a predefined tools.d
// pipeline task. It is always a writing capability (arbitrary process
// execution), so it is only registered when write is true. acl may be nil
// (see RegisterModules).
func RegisterRunPipeline(s *mcp.Server, policy *pipeline.Policy, write bool, acl *authz.ACL) {
	if !write {
		return
	}
	mcp.AddTool(s, &mcp.Tool{
		Name: "run_pipeline",
		Description: "" +
			"Run a chain of whitelisted commands piped together — stage N's stdout feeds stage " +
			"N+1's stdin — with no shell involved (no redirects, substitution, or globbing " +
			"beyond what each binary does itself). Each stage is [\"binary\", \"arg1\", \"arg2\", " +
			"...]; every stage's binary must appear in the server's configured command policy " +
			"(/etc/agentic-mcp/commands.yaml), and arguments are checked against that binary's " +
			"forbidden-pattern list. Returns the final stage's stdout/stderr/exit code; a " +
			"non-zero exit code is data, not a tool error. Prefer a predefined tools.d pipeline " +
			"task over this for anything used repeatedly — this tool is for ad hoc, one-off " +
			"chains.\n\n" +
			"Cross-tool equivalents: closest to ansible.builtin.shell's pipe support, Chef/Puppet/" +
			"Salt's various 'run this shell command' primitives (execute/exec/cmd.run), or a " +
			"Terraform local-exec/remote-exec provisioner — but whitelisted and shell-free rather " +
			"than an open shell invocation.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"stages": map[string]any{
					"type": "array",
					"items": map[string]any{
						"type":  "array",
						"items": map[string]any{"type": "string"},
					},
					"description": `Argv stages to chain, e.g. [["ps","aux"],["grep","nginx"],["wc","-l"]].`,
				},
			},
			"required": []string{"stages"},
		},
	}, func(ctx context.Context, req *mcp.CallToolRequest, in RunPipelineInput) (*mcp.CallToolResult, pipeline.Result, error) {
		if err := checkACL(ctx, acl, "run_pipeline", true); err != nil {
			return nil, pipeline.Result{}, err
		}
		res, err := pipeline.Run(ctx, policy, in.Stages, 0, 0)
		if err != nil {
			return nil, pipeline.Result{}, err
		}
		return nil, res, nil
	})
}
