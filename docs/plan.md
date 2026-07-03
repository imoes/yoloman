# Plan: `agentic-mcp` — AI-native Linux management system (Node Agent v1)

## Context & Vision

Today, running a fleet of servers requires **a handful of separate tools**:

- **CheckMK** → monitoring / health state
- **Coroot** → eBPF observability / service map
- **Ansible** → configuration / changes

In the age of AI, **a capable AI should be able to take over all of this**. The goal of this
product is to close the gap between these systems and replace them with **a single, AI-native
management layer** — observe (Coroot), assess (CheckMK), and change (Ansible) through *one*
declarative API, operable by an external AI.

### North-star UX: "describe the machine in prose"

The end user writes **in plain language / Markdown** how the machine should be configured — the
AI carries it out on its own. Example:

> "This server should run nginx, have port 443 open, timezone Europe/Berlin, a `deploy` user
>  with sudo, and `/etc/motd` set to our banner."

Flow (the AI orchestrates; the agent supplies the safe building blocks):

1. **Read current state** — `setup` (facts), `stat`, `service_facts`, … → the AI learns the
   actual state
2. **Plan** — call every affected module in **`check_mode`** → preview "what would change"
   (`changed: true|false`), without touching anything
3. **Apply** — only after approval / when `write:true`, idempotently (a second run changes
   nothing)

This is exactly what idempotent `ansible.builtin`-style modules with `check_mode` are built for:
prose → plan → apply becomes **reliable and safe**, not a blind shell flight. The reverse
direction is just as simple: **retrieving performance data** — `GET /api/v1/metrics/cpu?range=1h`
or resource `metrics://…`, with no query language to learn.

**Two components (deliberately separate, as with Prometheus/Coroot/CheckMK):**

| Component | Runs where | Responsibility | Language | When |
|---|---|---|---|---|
| **Node Agent** (`agentic-mcpd`) | on *every* server | /proc, commands+pipelines, eBPF, API mode, write gate, local TSDB | **Go** (static binary, CO-RE eBPF) | **v1 — this plan** |
| **Fleet Commander** | *once*, centrally | fleet API, aggregation, orchestration, MCP for the AI | **Python/FastAPI** | last step (separate plan) |

**Why Go for the agent** (confirmed by the user): eBPF à la Coroot needs `cilium/ebpf` + CO-RE
(one binary for every kernel, no clang/headers on the target), and zero-dependency distribution
across N servers is the core of the idea — a static binary instead of an interpreter+venv per
box. Python stays reserved for the central Commander layer, where it shines and matches the
existing `~/skills` stack.

## Differentiation / market gap (research findings)

- [rhel-lightspeed/linux-mcp-server](https://github.com/rhel-lightspeed/linux-mcp-server) (Python, read-only, via SSH from the outside) — no daemon on the host, no eBPF, no write, no package
- [tumf/mcp-shell-server](https://github.com/tumf/mcp-shell-server), [MladenSU/cli-mcp-server](https://github.com/MladenSU/cli-mcp-server), [sonirico/mcp-shell](https://github.com/sonirico/mcp-shell) — command execution only, no /proc, no eBPF, no fleet
- [Coroot](https://github.com/coroot/coroot) — excellent eBPF observability, but **no management/write**, no AI API
- **Cockpit** (Red Hat) — a web UI for *humans*, no stable automation API
- [SUSE MLM MCP](https://techcommunity.microsoft.com/blog/linuxandopensourceblog/getting-started-with-the-suse-multi-linux-manager-mcp-server-and-github-copilot/4513494) / [Red Hat AAP MCP](https://www.redhat.com/en/blog/it-automation-agentic-ai-introducing-mcp-server-red-hat-ansible-automation-platform) — MCP bolted *in front of* an existing management platform; here, we *are* the platform

**Nobody combines:** eBPF observability + a typed management API (read *and* write) +
zero-dependency agent + fleet orchestration, all AI-native via MCP. That's the gap.

## Node Agent v1 — Scope

1. **Structured /proc** — cpuinfo, meminfo, loadavg, uptime, mounts, net/dev, diskstats,
   `<pid>/status` → as JSON, not raw text
2. **`ansible.builtin` modules (native Go)** — the management verbs. Instead of wrapping raw
   binaries, the agent reimplements the well-known Ansible modules (`file`, `copy`, `template`,
   `service`, `systemd`, `apt`, `command`, `stat`, `find`, `lineinfile`, `user`, …) — **idempotent,
   with `check_mode`/dry-run and a `changed: true|false` report**, with no Ansible installation
   required. This is the capability set that "covers everything you'd do on Linux."
3. **Commands + pipelines** — for everything beyond the modules: whitelisted read-only commands
   (`fdisk -l`, `blkid`, …), pipelines (`cmd1 | cmd2 | …`) natively chained in Go, argv-based,
   per-stage argument policy (equivalent to `ansible.builtin.command`/`shell`, but controlled)
3. **eBPF observability (Coroot-style)** — TCP connection tracking + process exec events via
   `cilium/ebpf` (CO-RE); data in a local ring buffer + SQLite persistence
4. **Data storage** — **local SQLite** instead of RRD: a flexible schema holds both time series
   *and* labeled eBPF events (which RRD cannot do), queryable along any dimension, a single file,
   no external service, survives restarts. A **retention/downsampling job** (raw data → hourly/
   daily averages) gives the bounded size one would expect from RRD — without its rigidity.
   A DB abstraction exists; the Commander later uses MariaDB/PostgreSQL.

   **Implemented (step 6):** `internal/store` — a `Store` interface (`WritePoints`, `Query`,
   `Downsample`, `Close`) and a `modernc.org/sqlite`-backed implementation (pure Go, no cgo). A
   `Point` is `{metric, timestamp, value, labels map[string]string, resolution}`; labels are
   stored as canonical (sorted-key) JSON so identical label sets `GROUP BY` correctly during
   consolidation. `Downsample(rawCutoff, hourlyCutoff)` runs two consolidation passes — raw→hourly
   then hourly→daily — each averaging every `(metric, labels)` series' old points into
   bucket-aligned rows via one SQL `GROUP BY` query, inserting the consolidated rows, then
   deleting the source rows; safe to call repeatedly on a ticker. `config.DB.Retention`
   (`raw`/`hourly`/`interval`, parsed from strings like `"24h"`) drives a background retention
   loop in `main.go`. A `metrics_query` MCP tool (always active, matching the "retrieve
   performance data easily" requirement) reads the store with RFC3339-or-relative-duration time
   bounds and label filtering; a startup marker point is written on daemon start so the store has
   real, queryable data before the eBPF collector (step 10) exists. Verified end-to-end: the
   daemon wrote a real SQLite file, `metrics_query` returned the startup marker over live MCP,
   and the file's contents were independently confirmed with Python's stdlib `sqlite3` — a
   genuine, standards-compliant SQLite file, not a proprietary format.
5. **Two access modes:** **(a) MCP over Streamable HTTP** (for AI clients) and **(b) a plain
   REST API mode** (same capabilities, plain JSON — usable without an MCP client)
6. **Write gate:** a global `write: true|false` switch in the config (default `false`). When
   `false`, all mutating tools (`mode: put|update|delete`) are hard-disabled and never even
   registered. The architecture carries write from day one — v1 delivers the read foundation
   plus 1–2 first write tools as a reference (e.g. systemd service restart).
7. **Packaging** — `.deb` with a systemd unit; token auth; audit log

## Architecture (Node Agent)

```
External AI  ──MCP/HTTP──┐        Fleet Commander (Python, later) ──┐
Human/script  ─REST/HTTP─┤                                          │
                         ▼                                          ▼
┌────────────────────────────────────────────────────────────────────┐
│ agentic-mcpd  (systemd, Go)                                         │
│ ├─ internal/server   Mux: MCP (Streamable HTTP) + REST + web UI     │
│ │                    Auth: bearer token (AI) | PAM login (human)    │
│ ├─ internal/authz    PAM login, sessions, ACL enforcement           │
│ ├─ internal/webui    embedded admin frontend (go:embed)             │
│ ├─ internal/proc     /proc parser → JSON  (resources + proc_read)   │
│ ├─ internal/tools    registry (YAML tools.d/) + executor            │
│ │                    exec.go (argv), pipeline.go (native pipes)     │
│ │                    write gate (mode check against config.write)  │
│ ├─ internal/ebpf     CO-RE collector: TCP conns + exec events       │
│ │                    → ring buffer → store                          │
│ ├─ internal/store    DB abstraction (v1: SQLite), retention          │
│ └─ internal/audit    structured audit log per call → journald       │
└────────────────────────────────────────────────────────────────────┘
```

### The "API" — layers, one semantics

All layers expose the same capabilities, just a different protocol:

- **MCP resources** = GET on state: `proc://meminfo`, `net://connections`, `metrics://cpu?range=1h`
- **MCP tools** = actions with a `mode`: `get` (read) / `put|update|delete` (write, only when `write:true`)
- **REST** = classic: `GET /api/v1/proc/meminfo`, `GET /api/v1/net/connections`,
  `POST /api/v1/tools/{name}` (body = validated params). For automation without an MCP client.
  ACL management: `GET/PATCH /api/v1/acl/tools/{name}` (enable/disable), `GET/PUT /api/v1/acl/rules`.

  **Implemented (step 7):** `internal/server/rest.go` — `GET /api/v1/proc` (list) and
  `GET /api/v1/proc/{name}` (mirrors the MCP proc resources via the same `procResourceDefs`/
  `RenderProcResource`, no duplicated parsing logic), `GET /api/v1/tools` (list, respecting the
  write gate) and `POST /api/v1/tools/{name}` (dispatches to the same `modules.Registry`/`tasks.Task`
  list/`run_pipeline` used by MCP — one shared `components` struct in `main.go` feeds both layers
  so they can never drift apart), and `GET /api/v1/metrics/{metric}` (same time-bound/label-filter
  semantics as `metrics_query`). Mounted at `/api/v1/` behind the same bearer-token middleware as
  `/mcp`. Verified end-to-end: 401 without/with a wrong token, real live `/proc/meminfo` returned,
  a real task execution (`disk_list` running actual `fdisk -l`), a real 3-stage `run_pipeline`
  over the live process list, a real metrics query, and the write gate correctly returning 403 for
  `copy`/`run_pipeline` while `stat` stays 200 when `write:false`.
- **Web frontend** (`/ui`): PAM login; tool list from `tools.d/` with enable/disable switches;
  ACL rule editing; metrics/facts view; audit log. Self-contained (no external CDN).

### Module system (`ansible.builtin`-compatible, native Go)

The core of the agent is a set of **built-in modules** that reimplement `ansible.builtin`
modules — each one automatically becomes an MCP tool *and* a REST endpoint. Principles taken
directly from Ansible:

- **Same parameter names** as the Ansible module (`path`, `state`, `owner`, `mode`, `content`, …)
- **Idempotency** — the module checks the current state first, changes only if needed, reports `changed: true|false`
- **`check_mode`** (dry-run) — predicts the change without executing it. Mapping onto the write
  gate: read/dry-run is always allowed; **actually applying only when `write: true`**
- **No Ansible installation required** — a pure Go implementation (differentiation + zero dependency)

Module set (representative; "covers everything"):

- **Read/facts (always active):** `setup` (facts, as in Ansible), `stat`, `find`, `slurp` (read a
  file), `service_facts`, `package_facts`, `getent`, `command`/`shell` (read, see pipelines)
- **Write (only when `write:true`):** `file`, `copy`, `template`, `lineinfile`, `blockinfile`,
  `replace`, `service`, `systemd`, `apt`/`package`, `user`, `group`, `cron`, `sysctl`, `mount`,
  `get_url`, `hostname`, `timezone`
- v1 implements the **module framework** + all read/facts modules + a first write set (`file`,
  `copy`, `lineinfile`, `service`/`systemd`, `apt`, `command`); the rest follows module by module

**Descriptions are written like a skill, not a one-liner.** The goal is that an AI can take a
task from *any* configuration-management format — an Ansible playbook task, a Chef recipe
resource, a Puppet manifest type, a Salt state, a Terraform resource/provisioner — and translate
it into a call to one of these tools without external documentation. Every module's
`Description()` therefore includes: what it does and when to use it, then a "Cross-tool
equivalents" section naming the corresponding Ansible/Chef/Puppet/Salt/Terraform construct (or
noting there is none). `InputSchema()` returns an explicit, hand-written JSON Schema (not
inferred from a generic `map[string]any`) so parameter names, types, and per-parameter
descriptions are precise. All descriptions are in English. This pattern is established for the
v1 read modules and must carry through to the write modules (step 4) and the `tools.d` task
definitions (step 5).

### Tool definitions in `tools.d/` — as simple as an Ansible task

Every file in `/etc/agentic-mcp/tools.d/*.yaml` is essentially an Ansible task: a module call with
fixed/pre-supplied parameters. The user has nothing new to learn — **it *is* Ansible syntax**:

```yaml
# tools.d/restart_nginx.yaml — looks like an Ansible task
name: restart_nginx
description: "restart nginx"
ansible.builtin.service:          # module reference, as in a playbook
  name: nginx
  state: restarted
# mode is derived from the module + state (restarted ⇒ write); only active when write:true
```

```yaml
# tools.d/disk_list.yaml — a free-form command, still Ansible-module style
name: disk_list
description: "partition tables of all disks"
ansible.builtin.command:
  cmd: fdisk -l
```

```yaml
# tools.d/deploy_motd.yaml — a parameter to be filled by the caller (Ansible vars-style {{ }})
name: deploy_motd
description: "set the message of the day"
ansible.builtin.copy:
  dest: /etc/motd
  content: "{{ message }}"        # {{ }} = a validated parameter filled in by the caller
params:
  message: { type: string, required: true }
```

Free, generic module calls (without a tools.d file) are also possible: the AI can call a tool
like `file` / `service` directly with the Ansible parameters. `tools.d/` exists to **curate/
pre-configure** named, narrow actions (least privilege).

### Pipelines (part of the shell — but controlled)

Two ways, both **without `sh -c`**; the pipe is wired natively in Go (stdout→stdin):

1. **Predefined** in YAML: a `pipeline:` list of argv stages instead of an `ansible.builtin.*:` key
   (a tools.d file is exactly one or the other, never both)
2. **Ad-hoc** via the `run_pipeline` tool/REST endpoint: stages as argv arrays
   (`[["ps","aux"],["grep","nginx"],["wc","-l"]]`). Each stage is checked against
   `/etc/agentic-mcp/commands.yaml` (binary whitelist + argument policy; forbidden flags like
   `find -exec`, `-delete` are blocked). No redirects/substitution/globs via a shell.

**Implemented (step 5):** `internal/pipeline` (policy + native `exec.Cmd` stdout→stdin chaining,
timeout, output cap) and `internal/tasks` (the tools.d YAML parser: module tasks with
`{{ param }}` placeholder substitution — whole-value substitutions preserve the argument's native
type, partial/embedded substitutions are stringified — validated per-param via `type`/`required`/
`pattern` before substitution, and pipeline tasks). A task's write-gate status is derived
automatically: a module task inherits its underlying module's `Writes()`; a pipeline task is
always treated as writing, since arbitrary chained commands can't be assumed read-only. `run_pipeline`
itself is therefore also gated on `write:true`. Verified end-to-end against the real system:
`disk_list` (task wrapping `ansible.builtin.command`) ran real `fdisk -l`; `deploy_motd` (task with
`{{ message }}` substitution into `ansible.builtin.copy`) correctly surfaced a real permission
error against `/etc/motd`; `run_pipeline` ran a live `ps aux | grep agentic-mcpd | wc -l` through
three chained real processes and correctly rejected an unlisted binary (`rm`).

### eBPF collector (Coroot-style)

- `github.com/cilium/ebpf`, CO-RE (one binary, kernel ≥ ~5.8 with BTF)
- **TCP connection tracking** (kprobes on tcp_connect/tcp_accept) → who talks to whom, latency,
  failed attempts
- **Exec events** (tracepoint sched_process_exec) → what gets started
- Ring buffer → periodic flush into `internal/store` (SQLite), configurable retention
- Exposed as: `net_connections`, `top_talkers`, `exec_events(since)`, `metrics://…`
- **Graceful degradation:** no BTF / kernel too old → eBPF disabled, everything else keeps
  running (log warning)
- Inspiration: coroot-node-agent (Apache-2.0, Go) — the pattern is adopted, not the agent itself

### User management via PAM

- Authentication against the system PAM stack via `github.com/msteinert/pam` (cgo). A dedicated
  PAM service `/etc/pam.d/agentic-mcp` (defaults to delegating to `common-auth`). A user logs
  into the **web frontend / API** with their system username + password → PAM verifies it.
- Identity = system user + groups (`getgrouplist`). The daemon then issues a session token/cookie.
- **cgo note:** PAM forces cgo ⇒ the binary dynamically links against `libpam`/`libc` (present on
  every Linux system — in practice still effectively dependency-free). A `-tags nopam` build tag
  allows a fully static variant without PAM (token auth only) for special cases.

### ACL — enabling/disabling tools + authorization

Two layers, both manageable via **API and web frontend**, persisted in SQLite:

1. **Tool enable state** (global): every tool from `tools.d/` can be switched on/off. A disabled
   tool is not served (not registered, or 403) — a kill switch per capability.
2. **Per-user/group ACL:** rules mapping PAM identity → allowed tools + read/write permission
   (e.g. group `wheel` → all tools including write; `ops` → read-only tools). The bearer token
   (AI/machine) is its own service identity with its own ACL row.

- **Enforcement** happens centrally in the server before every dispatch: (a) is the tool active?
  (b) is the caller authorized per ACL? (c) write gate. Every decision goes into the audit log.

  **Implemented (step 8):** `internal/authz` — `PAMAuthenticator` (real `github.com/msteinert/pam/v2`
  cgo calls: `Authenticate` + `AcctMgmt`, then resolves group membership) returning an `Identity`;
  `SessionStore` (in-memory, TTL-based, opaque random tokens); `ACL` (SQLite-backed: `tool_state`
  table for the enable/disable kill switch, `acl_rules` table for principal→tools→write-permission
  rules) with `Authorize(identity, tool, writes) Decision`. **ACL semantics**: with zero rules
  configured, every enabled tool is allowed (opt-in layer, doesn't break installs that haven't
  set up ACL yet); once at least one rule exists, access becomes default-deny — identity must
  match a rule covering that tool, and a further rule must grant `allow_write` for write calls.
  A disabled tool is denied unconditionally regardless of rules.

  Wired into **both** protocols against the *same* ACL store: REST (`internal/server/rest.go`)
  resolves identity from a bearer token or a `Session <token>`/cookie (from
  `POST /api/v1/auth/login`, which calls PAM and creates a session), and enforces ACL in
  `handleToolCall`; MCP (`modules.go`/`tasks.go`) enforces the same `Authorize` call for every
  tool dispatch using the fixed `authz.TokenIdentity` (v1 has one shared bearer token — true
  per-connection MCP identity is listed under the v3 roadmap's "RBAC pro Token"). ACL admin REST
  endpoints: `GET/PATCH /api/v1/acl/tools/{name}`, `GET/PUT /api/v1/acl/rules` (both require
  `write:true`, since changing the security posture is itself a mutating operation).

  Verified with unit tests (real, non-mocked PAM calls via `pam_permit.so`/`pam_deny.so` through
  a throwaway `StartConfDir` service — success, denial, group-lookup-failure propagation; session
  create/resolve/expire/revoke; ACL rule matching for user/group/token principals, tool disable,
  write-permission scoping, rule-scoped tool lists) and end-to-end against the live daemon: PATCH
  disabling `stat` → 403, re-enabling → 200 again, the real SQLite ACL file inspected directly
  showing the persisted row, and — the key cross-protocol proof — an ACL rule added via
  `PUT /api/v1/acl/rules` (REST) correctly scoping the token identity on the **MCP** endpoint too
  (`stat` allowed, `copy` denied with the exact `Decision.Reason` string), confirming both access
  modes enforce identical rules from one shared store.

### Security model

- **No shell interpreter.** `exec.Command` + argv; parameters validated only via regex/enum;
  pipelines only from whitelisted stages; no redirects/substitution
- **Write gate:** `config.write=false` ⇒ mutating tools are not registered at all (not merely
  hidden). Layered above it: the ACL (per tool, per user/group/token)
- Minimal child environment, timeout + output cap per tool/pipeline
- Bearer token in `/etc/agentic-mcp/config.yaml` (mode 0600, `postinst` generates a random
  token), constant-time comparison; TLS/mTLS as an option
- eBPF needs elevated privileges ⇒ the daemon runs as root, tightly sandboxed via systemd:
  `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only`,
  `CapabilityBoundingSet=CAP_BPF CAP_PERFMON CAP_NET_ADMIN CAP_SYS_PTRACE CAP_DAC_READ_SEARCH`,
  `ReadWritePaths=/var/lib/agentic-mcp /var/log/agentic-mcp`
- **Audit:** every tool/write invocation as a JSON line (who/what/args/exit/duration) → journald

## Repository layout (`/home/mutkluge/Dev/code/Agentic-mcp/`)

```
cmd/agentic-mcpd/main.go        # flags: --config, --stdio, --listen
internal/proc/                  # /proc parser + tests (fixtures)
internal/modules/               # ansible.builtin modules (Go): module interface (check_mode,
                                 # changed), file.go, copy.go, service.go, apt.go, setup.go … + tests
internal/tools/                 # config.go, registry.go (module↔tool), taskyaml.go (Ansible task
                                 # parser for tools.d), pipeline.go, gate.go + tests
internal/ebpf/                  # collector.go, bpf/*.c (CO-RE), bpf2go-generated code, tests
internal/store/                 # store.go (interface), sqlite.go, retention.go + tests
internal/authz/                 # pam.go (login), session.go, acl.go (enforcement) + tests
internal/webui/                 # embed.go + assets/ (HTML/CSS/JS, self-contained)
internal/server/                # mcp.go, rest.go, acl_api.go, auth.go, health.go
internal/audit/                 # audit.go
configs/config.yaml              # listen, token, tls, write:false, ebpf:on, db:{driver,path},
                                 # pam:{service:agentic-mcp}, ui:{enabled:true}
packaging/pam.d-agentic-mcp      # /etc/pam.d/agentic-mcp (delegates to common-auth)
configs/commands.yaml            # binary whitelist + argument policies for run_pipeline
configs/tools.d/                 # Ansible-task style: restart_nginx, disk_list, deploy_motd …
packaging/nfpm.yaml               # .deb (later .rpm)
packaging/agentic-mcp.service     # hardened systemd unit
packaging/postinst / postrm       # create user/dirs, generate token, enable service
Makefile                          # build, generate(bpf2go), test, deb, run
README.md
```

## Work steps (each block individually testable → commit after each)

1. **Scaffold** — Go module, main.go, config loader (incl. `write`, `db`, `ebpf`), an empty MCP
   server over stdio. Test: `go build`, MCP handshake (Go client / Inspector)
2. **/proc resources** — parser + unit tests (real /proc fixtures), MCP resources + `proc_read`
   with a path guard (symlink/`..` tests)
3. **Module framework + read/facts modules** — module interface (`Check`/`Apply`, `changed`,
   `check_mode`), registry module↔tool↔REST. Read modules: `setup` (facts), `stat`, `find`,
   `slurp`, `service_facts`, `package_facts`, `getent`. Tests against real system state/fixtures.
   Reference: Ansible module docs for parameter names and return fields
4. **Write modules + write gate** — first write set (`file`, `copy`, `lineinfile`, `service`,
   `systemd`, `apt`, `command`), each idempotent + `check_mode`. `gate.go`: apply only when
   `config.write:true`, otherwise dry-run/`get` only. Tests: idempotency (2nd run =
   `changed:false`), check_mode changes nothing, write:false blocks apply
5. **tools.d/ (Ansible task parser) + pipelines** — `taskyaml.go` reads the Ansible task style
   (`ansible.builtin.<module>:` + params with `{{ }}`), produces named tools; native pipe
   chaining + `run_pipeline` + commands.yaml policy. Tests incl. injection (`; rm -rf`, `$(...)`),
   forbidden flags, "write tool not registered when write:false"
6. **Store (SQLite)** — DB interface + SQLite impl + retention/downsampling job (raw data →
   hourly/daily averages, bounded size). Tests: write/read, expiry, compaction
7. **HTTP: MCP + REST + auth** — Streamable HTTP MCP, REST router (`/api/v1/…`), bearer
   middleware (constant-time), `/healthz`. Test: curl with/without token, MCP client, REST call
8. **PAM + ACL + enforcement** — `authz`: PAM login (`msteinert/pam`), sessions, ACL store in
   SQLite (tool enable state + user/group/token rules), enforcement before every dispatch;
   ACL REST (`/api/v1/acl/…`). Tests: PAM login (test user), disabled tool → 403, group without
   write permission is blocked, token identity is honored
9. **Web frontend** — embedded admin UI (`go:embed`, self-contained): PAM login, tool
   enable/disable switches, ACL editor, metrics/facts, audit log. Test: browser login
   (Playwright), toggling a tool takes effect on the API immediately
10. **eBPF collector** — TCP conns + exec events (CO-RE, bpf2go), ring buffer→store, tools
    `net_connections`/`top_talkers`/`exec_events`, graceful degradation. Test (root): generate
    connections/processes → query via MCP/REST; degrade cleanly on a kernel without BTF
11. **Audit + systemd hardening** — audit logger, hardened unit. Test: a call → journald entry
12. **.deb** — nfpm.yaml, postinst (user, token, PAM file, enable). Test: install in a Debian
    Docker container, `systemctl status`, end-to-end query from outside (MCP *and* REST *and* UI)
13. **README** — install, extending the toolset, write gate, ACL/PAM, security model, eBPF prerequisites

## Build/verification prerequisites (packages)

So that **every** work step can be built *and* verified (rule: finish a module → verify →
proceed). Already present on this system: gcc/make, **bpftool**, **BTF in the kernel**
(`/sys/kernel/btf/vmlinux` ⇒ CO-RE works), kernel headers (6.17), Docker, Node/npx, curl/jq/git,
**claude CLI** (user context `~/.local/bin/claude`, logged in → serves as a real MCP client).

**Installed for this project:**

| Package | What for | From step |
|---|---|---|
| **Go** 1.26.4 (from go.dev) | the whole build/test flow (`go build`, `go test`) | 1 |
| `libpam0g-dev` | PAM login (cgo against libpam) | 8 |
| `clang` `llvm` `libbpf-dev` `libelf-dev` `zlib1g-dev` | compiling eBPF programs via bpf2go (CO-RE) | 10 |
| **nfpm** (`go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest`) | building the `.deb` | 12 |

Already usable for verification, **no extra package needed**: `go test` (unit/injection/gate),
`claude` as an MCP client, `curl`+`jq` for REST, `docker` for the clean-install test, Node/npx for
`@modelcontextprotocol/inspector` and Playwright (UI step), `bpftool` for eBPF debugging.

**Remote test host:** `host1.example.internal`, user `marvin`, key `~/.ssh/marvin.key`.
Available for later steps needing a real target beyond this dev machine — primarily the `.deb`
clean-install test (step 12) and systemd-hardening verification (step 11), where a disposable
real host is more representative than a local Docker container.

SQLite note: `modernc.org/sqlite` (pure Go, no cgo) — no system package needed.

## Verification (end to end)

- **Per step** (the working rule): `go test ./<package>/...` green + a functional smoke test of
  the block, only then commit and move on. At the end, `go test ./...` green overall.
- Start the daemon locally (with sudo for eBPF), then test it with the **installed claude CLI**
  as a real MCP client:
  `claude mcp add --transport http agentic-test http://localhost:8010/mcp --header "Authorization: Bearer <token>"`
  → read `proc://meminfo`, call `setup` (facts)/`stat`/`find`, check `net_connections`, call the
  `file`/`copy` module in `check_mode` (preview) and for real (idempotency: 2nd run
  `changed:false`), reject injection args, confirm write modules are **not registered** when
  `write:false` and present when `write:true`
- REST in parallel: `curl -H "Authorization: Bearer …" localhost:8010/api/v1/proc/meminfo`
- ACL/UI: `curl … PATCH /api/v1/acl/tools/disk_list {enabled:false}` → tool returns 403; PAM
  login in the frontend via Playwright, toggling a tool takes effect immediately
- Install the `.deb` in a fresh Debian Docker container → the service runs, a token is
  generated, and a query from outside succeeds

## Planned near-term addition: Nagios/CheckMK-compatible custom checks

A `check` task kind alongside the existing module/pipeline tools.d kinds: runs a script/binary
like a standard Nagios/CheckMK plugin (exit code 0/1/2/3 = OK/WARNING/CRITICAL/UNKNOWN, stdout's
first line optionally carrying `|`-delimited perfdata) and returns the parsed status + message +
perfdata as structured JSON — an MCP/REST tool like any other. Only a `description` is required
per check (mirroring the cross-tool-equivalents pattern from step 3) so the AI understands what
the check monitors without needing external documentation; the check binary itself can be an
existing Nagios/CheckMK plugin (`check_disk`, `check_http`, a custom script, …), giving instant
compatibility with the existing plugin ecosystem. To be implemented right after step 8.

## Roadmap (after this v1 — separate plans)

- **Module completion:** the remaining `ansible.builtin` write modules (`template`,
  `blockinfile`, `user`, `group`, `cron`, `sysctl`, `mount`, `get_url`, `hostname`, `timezone`,
  `package`). Optionally: multi-task plan/apply (playbook-style) with confirmation — the full
  Ansible replacement
- **Fleet Commander (Python/FastAPI, the last step):** agent registry, fleet-wide aggregation in
  MariaDB/PostgreSQL, cross-host service map, an MCP facade for the AI, alerting (the CheckMK
  replacement), discovery via NetBox
- **v3:** mTLS, per-token RBAC (token → allowed tool set), `.rpm`, eBPF expansion (disk I/O
  latency, container awareness)
