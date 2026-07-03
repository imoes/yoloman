// Command agentic-mcpd is the agentic-mcp node agent: it exposes Linux system
// state and management actions to AI clients via MCP (stdio or Streamable
// HTTP) and a plain REST API.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/mutkluge/agentic-mcp/internal/config"
	"github.com/mutkluge/agentic-mcp/internal/pipeline"
	"github.com/mutkluge/agentic-mcp/internal/server"
	"github.com/mutkluge/agentic-mcp/internal/tasks"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "agentic-mcpd:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("agentic-mcpd", flag.ContinueOnError)
	configPath := fs.String("config", "/etc/agentic-mcp/config.yaml", "path to config.yaml")
	stdio := fs.Bool("stdio", false, "serve MCP over stdio instead of Streamable HTTP")
	listen := fs.String("listen", "", "override the listen address from config")
	if err := fs.Parse(args); err != nil {
		return err
	}

	cfg, err := loadConfigOrDefault(*configPath)
	if err != nil {
		return err
	}
	if *listen != "" {
		cfg.Listen = *listen
	}

	mcpServer, err := newServer(cfg)
	if err != nil {
		return err
	}

	if *stdio {
		return mcpServer.Run(context.Background(), &mcp.StdioTransport{})
	}

	return serveHTTP(cfg, mcpServer)
}

// loadConfigOrDefault loads the config file if present, else falls back to
// Default() so the daemon can start with `--stdio` for local testing without
// requiring /etc/agentic-mcp/config.yaml to exist yet.
func loadConfigOrDefault(path string) (config.Config, error) {
	if _, err := os.Stat(path); err != nil {
		slog.Warn("config file not found, using defaults", "path", path)
		return config.Default(), nil
	}
	return config.Load(path)
}

// newServer builds the MCP server with all resources/tools registered.
// Registration grows in later steps (ebpf, ...).
func newServer(cfg config.Config) (*mcp.Server, error) {
	s := mcp.NewServer(&mcp.Implementation{
		Name:    "agentic-mcp",
		Version: "0.1.0",
	}, nil)
	server.RegisterProc(s, "/proc")

	modReg := server.NewDefaultModuleRegistry()
	server.RegisterModules(s, modReg, cfg.Write)

	policy := loadCommandPolicyOrEmpty(cfg.CommandsFile)
	server.RegisterRunPipeline(s, policy, cfg.Write)

	taskList, err := tasks.LoadDir(cfg.ToolsDir)
	if err != nil {
		return nil, fmt.Errorf("loading tools.d: %w", err)
	}
	if err := server.RegisterTasks(s, taskList, modReg, policy, cfg.Write); err != nil {
		return nil, err
	}

	return s, nil
}

// loadCommandPolicyOrEmpty loads the pipeline command policy if the file
// exists, else falls back to an empty (allow-nothing) policy — the safe
// default when no commands.yaml is configured.
func loadCommandPolicyOrEmpty(path string) *pipeline.Policy {
	if _, err := os.Stat(path); err != nil {
		slog.Warn("command policy file not found, pipelines will allow no commands", "path", path)
		return pipeline.EmptyPolicy()
	}
	p, err := pipeline.LoadPolicy(path)
	if err != nil {
		slog.Warn("failed to load command policy, pipelines will allow no commands", "path", path, "error", err)
		return pipeline.EmptyPolicy()
	}
	return p
}
