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
	"github.com/mutkluge/agentic-mcp/internal/server"
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

	mcpServer := newServer(cfg)

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
// Registration grows in later steps (modules, tools.d, ebpf, ...).
func newServer(cfg config.Config) *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{
		Name:    "agentic-mcp",
		Version: "0.1.0",
	}, nil)
	server.RegisterProc(s, "/proc")
	server.RegisterModules(s, server.NewDefaultModuleRegistry(), cfg.Write)
	return s
}
