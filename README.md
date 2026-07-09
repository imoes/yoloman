# YOLO-MANager (`agentic-mcp`)

![Yolo Man — Full Managed MCP Server](docs/assets/yolo-man.jpg)

> *"You only live once — but your servers only get one uptime SLA, so let's not get carried
> away."*

A self-contained Linux node agent that hands your server's monitoring, observability, and
configuration management over to an AI — over [MCP](https://modelcontextprotocol.io) (stdio or
Streamable HTTP) and a plain REST API. No Ansible, no SSH agent, no Python runtime required on the
managed host. Ships as a single static Go binary with a hardened systemd unit.

Think CheckMK (monitoring) + Coroot (eBPF observability) + Ansible (configuration management),
minus the three separate tools, plus one thing they don't have: an API built for a language model
to actually drive.

The daemon itself goes by **Duppy** — Jamaican patois for a spirit that lingers unseen and does
things in the background, which is coincidentally also why Unix daemons are spelled that way in
the first place (the old hacker folklore insists it's the *helpful* kind of supernatural entity,
not the evil one). Duppies in actual Jamaican folklore have a bit of a reputation for mischief;
ours mostly just watches `/proc` and restarts services on request.

## Is This Actually a Good Idea?

Let's be honest about the name for a second. "YOLO" as an engineering philosophy has a well-earned
reputation, and the internet has receipts. The original ["YOLO deployment" meme](https://hackernoon.com/could-yolo-driven-development-be-a-thing-fa1c12242188)
is about skipping the test suite and shipping straight to prod on a Friday afternoon — the joke
being that your CI pipeline becomes "CI/See-No-Evil" and whatever breaks becomes [tomorrow-you's
problem](https://www.cloudzero.com/blog/devops-memes/). And handing infrastructure to an *autonomous
agent* specifically has its own, less funny research trail: [Gartner predicts 40% of enterprises
will decommission autonomous AI agents by 2027](https://www.gartner.com/en/newsroom/press-releases/2026-05-26-gartner-says-applying-uniform-governance-across-ai-agents-will-lead-to-enterprise-ai-agent-failure)
after governance gaps surface in production, and the recurring root cause in the [2025 AI agent
security literature](https://www.obsidiansecurity.com/blog/ai-agent-market-landscape) is
over-permissioning — agents quietly handed more access than their job needs, with no way to dial
it back.

So, fair question: why would you point something called YOLO-MANager at your infrastructure?

Because unlike an actual YOLO deploy, nothing here is a blind commit to prod. Every mutating
action goes through the same idempotent, Ansible-shaped module first in `check_mode` — a full dry
run preview of exactly what would change, with nothing touched — before it's ever allowed to run
for real. Real execution requires the operator to explicitly flip a global `write: true` switch in
config.yaml; leave it `false` (the default) and every mutating tool isn't just hidden, it's never
even registered. Layered on top: a per-user/per-token ACL with a kill switch for every individual
tool, and a structured audit log of every call, straight to journald. The Gartner finding above —
that governance fails when it's all-or-nothing instead of graduated — is more or less this
project's whole design brief.

In short: we kept the "let an AI run your servers" idea, and deliberately did not keep the "skip
the safety checks" part the name jokes about. Read the full model in
[docs/plan.md](docs/plan.md#security-model) if you want to see the trade-offs made explicit.

## What's implemented

- **A full built-in module library, native in Go** — `file`, `copy`, `lineinfile`, `apt`,
  `command`, `raw`, `script`, `service`/`systemd`/`systemd_service`, `sysvinit`, `blockinfile`,
  `replace`, `assemble`, `tempfile`, `template`, `user`, `group`, `cron`, `hostname`, `timezone`,
  `apt_key`, `apt_repository`, `deb822_repository`, `dpkg_selections`, `debconf`, `yum`, `dnf`,
  `dnf5`, `yum_repository`, `rpm_key` (the RedHat-family package modules are unit-tested only —
  this project's real test host is Debian), `package`, `pip`, `git`, `subversion`, `unarchive`,
  `expect`, `reboot`, `get_url`, `uri`, `known_hosts`, `iptables`, plus read-only facts (`setup`,
  `stat`, `find`, `slurp`, `fetch`, `wait_for`, `ping`, `service_facts`, `package_facts`,
  `getent`). Idempotent, `check_mode`-aware, `changed: true/false` reporting — no Ansible
  installation required on either end. One deliberate exception to the "no shell, argv only"
  design the rest of this set follows: `shell`, which genuinely runs `/bin/sh -c` (pipes,
  redirects, globbing) because that's the entire point of the real Ansible module it mirrors —
  see [docs/plan.md](docs/plan.md#security-model) for the trade-off. Every module's description
  names its Ansible/Chef/Puppet/Salt/Terraform equivalent, so an AI can translate a task from any
  of those formats without external docs. See [docs/plan.md](docs/plan.md) for the module-by-module scope, the batches it
  was built in, and how each one was verified.
- **`tools.d/`** — curated, named tool definitions written in literal task YAML
  (a bare `<module>:` key + `{{ placeholder }}` params), plus native argv command pipelines
  (`cmd1 | cmd2`, no shell) with a binary/argument whitelist.
- **Nagios/CheckMK-compatible custom checks** — drop in any Nagios plugin, exposed as an MCP tool
  automatically.
- **eBPF observability** (Coroot-style) — TCP connection tracking, process-exec events, and disk
  I/O latency (block request issue/completion correlated in-kernel by device+sector) via
  `cilium/ebpf`, CO-RE-free stable tracepoints, graceful degradation on kernels without ring buffer
  support. Every event is container-aware — a best-effort container ID resolved from
  `/proc/<pid>/cgroup`, recognizing Docker's own cgroup driver, Docker-via-systemd, and
  containerd/CRI paths uniformly, without walking fragile kernel cgroup structs.
- **Local SQLite metrics store** with a retention/downsampling job (raw → hourly → daily), plus a
  bulk `metrics_dump` endpoint for efficient polling.
- **PAM login + SQLite-backed ACL, with per-token RBAC** — a per-tool kill switch and per-
  user/group/token rules, enforced identically whether the caller comes in over MCP or REST.
  Beyond the single legacy bearer token, `config.yaml` can name additional tokens
  (`tokens: [{name, token}]`), each resolving to its own ACL identity — so a CI pipeline and a
  future Bossman instance can be scoped to different tool sets instead of every valid token
  granting the same access.
- **Self-contained embedded web admin UI** — login, tool toggles, ACL editing, metrics/facts
  viewing. No build step, no CDN.
- **Structured audit logging** — every tool call as a JSON line to journald.
- **Hardened systemd unit** — privilege-escalation and kernel-attack-surface hardening; explicitly
  *not* filesystem/capability-sandboxed, because the entire point of this daemon is open-ended
  system management (see [docs/plan.md](docs/plan.md) for why that trade-off was made deliberately,
  not by accident).
- **Three operating modes** — `standalone` (fully self-contained, the default), `satellite` (a
  central Fleet Commander pulls this agent's data), and `proxy`, nicknamed **Selecta** (this agent
  pulls from a list of satellites over TLS and re-serves the aggregate, for firewalled or
  distributed networks — a soundsystem selector working the crowd's whole set from one deck).
  Machine-to-machine access is authorized via TLS client certificates pinned per caller — the SSH
  `authorized_keys` model, over TLS, checked in addition to the existing bearer token.
- **`agentic-mcpd register`** — a one-time enrollment handshake with the future Bossman: trades a
  shared bootstrap secret for Bossman's public key, so it can be added to `tls.trusted_client_keys`
  without copying key files around by hand. `agentic-mcpd --generate-token` mints a fresh random
  bearer token for `config.yaml`, independently of enrollment.
- **`upload_file` (MCP) / `PUT /api/v1/upload` (REST)** — stages a new file (a config snippet, a
  `.deb` package) onto the host before `copy` places it at its final destination. The MCP tool
  takes small base64 content (≲64 KiB — anything an AI would plausibly compose inline); the REST
  endpoint streams a raw request body straight to disk, no base64, sized for real packages (kernel
  packages run up to ~274 MiB).
- **`.rpm` packaging** (`packaging/nfpm.yaml`) — one shared `nfpm` config builds both `.deb` and
  `.rpm`; `postinst` bootstraps `config.yaml` with a freshly generated token on first install and
  enables the systemd unit, `postrm` stops the service without ever deleting the token/store/audit
  history. Real-installed and run under genuine `systemd` in a Rocky Linux 9 container.

## The Fleet Commander: Bossman

![Bossman — Linux Solutions](docs/assets/bossman.jpg)

The Node Agent (this repo) runs on every server. A separate central component — codename
**Bossman** (Jamaican patois for "the boss," a fitting counterpart to YOLO-MAN: he runs on every
machine, Bossman keeps an eye on the whole fleet) — aggregates the fleet, translates Ansible
playbooks (and, via a real LLM-backed translator, arbitrary foreign automation sources) into this
agent's own module calls, and gives an AI one MCP endpoint for the whole infrastructure instead of
one per box. Lives in [`bossman/`](bossman/) (backend) and [`bossman-ui/`](bossman-ui/) (frontend);
see [docs/plan.md](docs/plan.md) for the full, continuously-updated implementation record.

**Try the whole Bossman stack locally** with Docker Compose — Postgres/TimescaleDB, migrations, an
`admin`/`admin123` seed user, the FastAPI backend, and the Angular frontend behind nginx:

```bash
docker compose up -d --build
```

Then open the URL `docker-compose.override.yml` publishes for `bossman-ui` (`4201` by default in
this checkout — see that file's comments for why, and adjust it for your own machine's free ports)
and sign in with `admin` / `admin123`. `docker-compose.yml` is the portable, shareable stack
definition; `docker-compose.override.yml` (merged in automatically, no `-f` flag needed) is where
anything specific to *your* machine belongs — port choices, an outbound proxy, etc.

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

Without a config file, the daemon falls back to built-in defaults (listening on `127.0.0.1:8010`,
write disabled) for quick local testing.

## Test

```bash
go test ./...
```

## Playbooks

Plans (and the agent's local `tools.d` tasks) can be written in
[NestedText](https://nestedtext.org) instead of YAML — all-strings, no
implicit typing, no quoting — and run with the `yolo-man` CLI
(`lint`/`show`/`convert`/`run`). See
[`docs/nestedtext-playbooks.md`](docs/nestedtext-playbooks.md).

## Learn more

The full design — architecture, module system, security model, the three operating modes, and the
complete roadmap — lives in [`docs/plan.md`](docs/plan.md).
