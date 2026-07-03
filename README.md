# agentic-mcp

A self-contained Linux node agent that exposes system state and management
actions to AI clients over [MCP](https://modelcontextprotocol.io) (stdio or
Streamable HTTP) and a plain REST API — no Ansible, no SSH agent, no Python
runtime required on the managed host.

Ships as a single static Go binary + `.deb` package with a hardened systemd
unit. See the design and full roadmap in
[`docs/plan.md`](docs/plan.md).

## Status

Early scaffold. Currently implemented:

- Config loader (`internal/config`) — YAML config with safe defaults
  (`write: false` unless explicitly enabled).
- `agentic-mcpd` binary — starts an MCP server over stdio (`--stdio`) or
  Streamable HTTP (default), with bearer-token auth and a `/healthz` endpoint.

Not yet implemented: `/proc` resources, `ansible.builtin`-style management
modules, tools.d task definitions, pipelines, SQLite storage, PAM/ACL, the
web UI, and the eBPF collector — tracked in the roadmap.

## Build

```bash
go build -o bin/agentic-mcpd ./cmd/agentic-mcpd
```

## Run

```bash
# MCP over stdio (for local testing with an MCP client)
./bin/agentic-mcpd --stdio --config configs/config.yaml

# MCP over Streamable HTTP (default) + REST, listens on config.yaml's `listen`
./bin/agentic-mcpd --config configs/config.yaml
```

Without a config file, the daemon falls back to built-in defaults (listening
on `127.0.0.1:8010`, write disabled) for quick local testing.

## Test

```bash
go test ./...
```
