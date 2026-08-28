# The Windows agent — build and run

Design and decisions: [`docs/windows-agent.md`](../docs/windows-agent.md).

```
AgenticMcp.Agent.Core      net10.0          the contract with Bossman: wire shapes, metric store,
                                            module protocol, mTLS pinning. CROSS-PLATFORM on purpose.
AgenticMcp.Agent.Host      net10.0          the agent process: TLS listener, collection loop, enrolment
AgenticMcp.Agent.Windows   net10.0-windows  the WMI collector — the only Windows-only project
AgenticMcp.Agent.Tests     net10.0          the contract, asserted on the WIRE
```

**Why Core is cross-platform.** Everything that has to agree with Bossman lives there, so the whole first
milestone was proven on the Linux dev host against the running server before a Windows VM existed. Every
disagreement about the wire surfaced where a rebuild costs two seconds — including the two that mattered:
Bossman polls over **https with a client certificate**, and it was doing so **through the corporate proxy**
(fixed in `bossman/services/agent_client.py`, and that fix brought a real host back).

## Build and test

```bash
export PATH="$HOME/.dotnet:$PATH"        # SDK 10.0.400, installed user-local (no root available)
dotnet test  windows-agent/AgenticMcp.Agent.Tests
dotnet build windows-agent/AgenticMcp.Agent.Windows      # compiles on Linux; WMI only RUNS on Windows
```

## Run it against a Bossman

```bash
AGENT_NAME=win-test \
AGENT_TOKEN=$(openssl rand -hex 24) \
AGENT_LISTEN=0.0.0.0:8451 \
AGENT_ADDRESS=<the host:port Bossman can reach> \
BOSSMAN_URL=http://bossman:8123 \
AGENT_STATE_DIR=/var/lib/agentic-mcp \
dotnet run --project windows-agent/AgenticMcp.Agent.Host
```

It enrols first, writes the returned public key to `$AGENT_STATE_DIR/bossman-public-key.pem`, creates a
self-signed server certificate beside it, and only then binds. Bossman needs no configuration: the agent
appears in the fleet and is polled on the next cycle.

| Variable | Default | |
|---|---|---|
| `AGENT_NAME` | machine name | what Bossman calls this host |
| `AGENT_TOKEN` | generated, printed once | the bearer token Bossman must present |
| `AGENT_LISTEN` | `0.0.0.0:8051` | the Go agent's port, so nothing downstream has to know which agent it is |
| `AGENT_ADDRESS` | `AGENT_LISTEN` | the address Bossman can actually reach |
| `BOSSMAN_URL` | none | enrol on start; without it the agent only listens |
| `AGENT_WRITE` | closed | `true` opens the write gate |
| `AGENT_STATE_DIR` | `./state` | TLS certificate and the pinned key |

## Publishing for Windows

```bash
dotnet publish windows-agent/AgenticMcp.Agent.Host -r win-x64 -c Release
```

Self-contained single-file, so the target needs no runtime install. The MSI that registers it as a service
is milestone 6.
