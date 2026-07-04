# Plan: YOLO-MANager (`agentic-mcp`) — AI-native Linux management system (Node Agent v1)

**Project name:** YOLO-MANager — the user-facing brand (MCP server title, web UI, systemd
description); `agentic-mcp` remains the underlying Go module path, binary name, and config/data
directory names (`/etc/agentic-mcp`, `/var/lib/agentic-mcp`, ...), since a full technical rename
touches every file's import path for no functional benefit. See `docs/assets/yolo-man.jpg` for
the mascot.

**The running daemon itself is nicknamed "Duppy"** — Jamaican patois for a ghost/spirit, chosen
because it lines up with genuine Unix folklore (a "daemon" was named for a *helpful* supernatural
entity, not an evil one) the same way a duppy is Jamaica's own version of an unseen, lingering
presence. Branding only, same split as above: `agentic-mcpd` stays the binary/directory/module
name; "Duppy" appears in prose, the systemd unit's Description, and the README.

Fitting alongside the other in-universe nicknames established so far: **Bossman** (the future
Fleet Commander, see Roadmap) and **Selecta** (this agent's `proxy` operating mode, see "Three
operating modes" below).

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

  **Implemented (step 9):** `internal/webui` — a single self-contained `index.html`
  (`go:embed`, no external CDN/build step, plain HTML/CSS/vanilla JS) mounted at `/ui/`,
  served as public static assets (the page itself authenticates against `/api/v1/` once
  loaded — either PAM username/password via `/api/v1/auth/login`, or pasting the bearer
  token directly). Three views: **Tools** (live list with kind/read-write tag/enable switch,
  `PATCH /api/v1/acl/tools/{name}` on toggle), **ACL Rules** (table + add-row form +
  `PUT /api/v1/acl/rules` bulk save), **Facts & Metrics** (`setup` module + `metrics_query`
  via REST). No separate audit-log view yet — deferred until step 11 actually produces
  audit data, rather than shipping a UI panel for nonexistent data.

  Fixed a real latent bug found while wiring this up: `cmd/agentic-mcpd/http.go` was
  double-gating `/api/v1/` — `rest.go`'s own `withIdentity` middleware (bearer **or**
  session) was wrapped by the *old* bearer-only `withBearerAuth` from step 7, which would
  have silently rejected every PAM-session login at the transport layer. The step 8 unit
  tests never caught this because they call `NewRESTHandler`'s output directly, bypassing
  `http.go` entirely. Removed the redundant outer wrapper.

  Verified with a real, browser-driven Playwright session against the live daemon (not
  just Go `httptest`): logged in via the API-token tab, saw all 20 real registered tools;
  clicked a tool's enable switch off — confirmed via `curl` that the ACL row flipped to
  `enabled:false` *and* a direct call now 403s; toggled it back on and confirmed 200 again;
  loaded real facts (`host4.example.internal`, Ubuntu 24.04, 8 vCPUs, 32GB) and the real startup
  metric point; added an ACL rule through the form UI, saved it, confirmed via `curl` it
  persisted in SQLite *and* correctly flipped the system to default-deny (the token identity's
  own `stat` call now 403'd, since no rule covered "token"); removed the rule through the UI,
  saved, confirmed reversion to allow-all; logged out and confirmed return to the login screen.

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

**Implemented (step 10) — design refinement:** the actual implementation uses **tracepoints
instead of kprobes**, specifically `sock:inet_sock_set_state` (covers both connect() and
accept() completions as transitions to `ESTABLISHED`, plus every other state change) and
`sched:sched_process_exec`, both hardcoded from their real, verified `format` layout (via
`bpftool btf dump file /sys/kernel/btf/vmlinux format c`) rather than via CO-RE/vmlinux.h. This
is a deliberate simplification over the original kprobe+CO-RE plan: both tracepoints are part of
the kernel's **stable tracepoint ABI** (the `/sys/kernel/tracing/events/.../format` contract
does not change across kernel versions the way raw kernel struct layouts do), so no BTF
relocation is needed at all for reading their arguments — only `BPF_MAP_TYPE_RINGBUF` still sets
the practical minimum kernel version (~5.8). `internal/ebpf/bpf/collector.c` (+
`tracepoints.h`) is compiled via `bpf2go` (`go generate`, needs clang/libbpf-dev only when
regenerating); the resulting `.go`+`.o` are committed and embedded (`go:embed`), so a plain
`go build` needs no BPF toolchain. `internal/ebpf.Collector` loads/attaches both programs,
reads the shared ring buffer, and keeps bounded in-memory event lists (`RecentConns`,
`RecentExecs`, `TopTalkers` — aggregated by comm+destination over `ESTABLISHED` transitions).
IPv4 only in v1 (IPv6 still not implemented). Graceful degradation is real: `startEBPFCollector`
in `main.go` logs a warning and returns `nil` on any failure (missing CAP_BPF, old kernel, ...),
and every registration point (`RegisterEBPF`, `RegisterEBPFRoutes`) is a no-op for a nil collector
— verified locally in this sandbox (no root) where the daemon started fine with the log warning
and the eBPF tools were simply absent.

**Extended in v3** with two more stable tracepoints (`block:block_rq_issue`/`block:block_rq_complete`
for disk I/O latency) and `/proc`-based container-awareness enrichment on every event type — see
the "v3" section below for full detail and real-verification evidence.

Verified for real on the remote test host (`host1.example.internal`, kernel 6.12.94,
Debian 13, real root via `sudo`): the eBPF programs loaded and attached successfully
("`eBPF collector attached`"), and `net_connections`/`top_talkers`/`exec_events` captured
**genuine kernel activity** — the daemon's own listening-socket transition, a real `curl` to
`example.com`'s actual IP over TLS, the complete real TCP lifecycle of ad hoc `curl` calls
against the daemon's own API (`CLOSE→SYN_SENT→ESTABLISHED→FIN_WAIT1`/`CLOSE_WAIT`), real
background SSH/Kerberos/LDAP traffic from the very SSH session used to run these tests, and the
entire real process chain of an SSH login's MOTD scripts (`sss_ssh_authorizedkeys` →
`selinux_child` → `run-parts` → `10-uname` → `bash` → `curl`). This surfaced and fixed a real
bug: `net.IP` marshals to JSON as a string (via `MarshalText`), but its underlying Go type
(`[]byte`) makes JSON-Schema inference describe it as an array — a genuine schema/runtime
mismatch that the MCP Inspector's strict client-side validator caught (`CallTool` failed with a
type-mismatch error) when calling `top_talkers`/`net_connections` over the real MCP protocol.
Fixed by using plain dotted-decimal strings for all address fields instead of `net.IP`,
redeployed to the remote host, and re-verified the exact same MCP calls succeed.

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
  pipelines only from whitelisted stages; no redirects/substitution — **with one deliberate,
  explicitly confirmed exception: the `shell` module** (`internal/modules/shell.go`, part of
  Batch 6's `ansible.builtin` coverage). Real Ansible's `shell` exists specifically to run shell
  syntax (pipes, redirects, globbing, `$()`) that an argv array cannot express; implementing it
  faithfully means `/bin/sh -c <string>` and therefore genuinely does reintroduce shell-injection
  surface for that one tool. This trade-off was raised explicitly and confirmed by the project
  owner rather than made unilaterally — the module's own description carries the same warning
  for any AI client reading tool docs before calling it: don't pass untrusted content into `cmd`,
  and prefer `command`/`raw` (argv-only, no shell) whenever shell syntax isn't actually needed.
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

## Nagios/CheckMK-compatible custom checks (implemented after step 8)

A third tools.d task kind, `check:`, alongside the existing module (`ansible.builtin.*:`) and
`pipeline:` kinds — mutually exclusive with both. Runs a script/binary following the standard
Nagios Plugin API (also used by CheckMK's local/MRPE checks): exit code 0/1/2/3 =
OK/WARNING/CRITICAL/UNKNOWN, stdout's first line as `<message>[ | <perfdata>]`, further lines as
long-output. `internal/checks` parses this into `{status, message, long_output, perfdata[],
exit_code}`. Only a `description` is required per check (same cross-tool-equivalents philosophy
as step 3) — the check binary itself can be an existing Nagios/CheckMK plugin (`check_disk`,
`check_http`, …) or a custom script following the same convention, giving instant compatibility
with the existing plugin ecosystem with zero adapter code.

A check task is always read-only (`Writes()` is always `false`) and therefore always registered
regardless of the write gate — a monitoring check inspects and reports, it never mutates state.
`{{ param }}` placeholder substitution works exactly as for module/pipeline tasks (e.g. a
`{{ warn_threshold }}` argument).

Verified with unit tests (Nagios-format parsing incl. perfdata with full
label/warn/crit/min/max, multi-line long-output, empty output, real subprocess exit codes via
`/bin/sh`; task-level: parsing, always-read-only, placeholder substitution, missing-required-param
rejection) and end-to-end: `configs/tools.d/check_root_disk.yaml` — a real, self-contained
Nagios-style plugin (checks `df -P /` against 80%/90% thresholds, no external plugin package
needed) — registered and callable via both MCP and REST even with `write:false`, returning the
real root filesystem usage (verified against `df` directly) with correctly parsed status,
message, and perfdata.

## Step 11 — audit logging + systemd hardening (implemented)

`internal/audit`: a `Logger` writing one JSON line per tool/module/task/pipeline dispatch to
stderr — under systemd this lands in the journal automatically, and being valid JSON it's
directly consumable via `journalctl -u agentic-mcp -o cat | jq` with no native journal-protocol
dependency. Each entry: `time`, `identity` (`kind:name`, e.g. `token:service-token` or
`user:alice`), `tool`, `write`, `changed`, `params` (values under a key containing "password"/
"secret"/"token" are redacted), `duration_ms`, `error` (omitted on success). Wired into every
dispatch point on both protocols — MCP (`registerModuleTool`, `registerTaskTool`,
`run_pipeline`) and REST (`handleToolCall`) — via a nil-safe `*audit.Logger` (a nil logger is a
no-op, so call sites never branch on whether auditing is configured).

**systemd hardening — a deliberate design correction from the original plan.** The original
plan text (see "Security model" above) called for `ProtectSystem=strict` with narrow
`ReadWritePaths` and a capability allow-list. Implementing `packaging/agentic-mcp.service`
surfaced that this would silently break the product's core feature the moment `write:true` is
set: a filesystem sandbox can't distinguish "the AI editing `/etc/nginx.conf` on purpose" from
an attacker doing the same, and a narrowed `CapabilityBoundingSet` would block apt/dpkg
maintainer scripts, user/group management, and file ownership changes. Confirmed with the user:
**no filesystem/capability sandbox** — access control is enforced at the application layer (ACL
+ write gate + audit log) instead, since the daemon's job is genuinely open-ended system
management. The unit file keeps every hardening directive that narrows privilege
*escalation* and kernel attack surface *without* conflicting with any implemented module
(`NoNewPrivileges`, `PrivateTmp`, `ProtectKernelModules`, `ProtectControlGroups`, `ProtectClock`,
`ProtectHostname`, `RestrictRealtime`, `RestrictNamespaces`, `LockPersonality`,
`MemoryDenyWriteExecute`, `RemoveIPC`) — each verified against actual implemented behavior (e.g.
`ProtectKernelLogs` was deliberately left off because the `recent_log_errors` example pipeline
uses `dmesg`, which it would have blocked).

Verified: `systemd-analyze verify` reports no errors/warnings on the unit file; the daemon was
run as a real transient systemd unit (`systemd-run --user`, journal-backed stdout/stderr — no
full package install needed for this check, which is step 12's job) and three real API calls
(a read, a write, and one that errors on a missing parameter) each produced a correctly
structured, `jq`-parseable audit line in `journalctl`, including `changed:true` on the
successful write and the exact validation error message on the failing call.

## Three operating modes: standalone / satellite / proxy ("Selecta")

A node agent can run in one of three modes (`mode:` in config.yaml), reflecting how its
performance data relates to a central Fleet Commander — the CheckMK site/proxy/agent hierarchy
adapted to this project's MCP/REST-native design:

1. **Standalone** (default, current v1 behavior) — all performance metrics are stored and
   served locally only. No relationship to any other agent or a Commander.
2. **Satellite** — the same agent, but a central Fleet Commander is expected to pull this
   agent's data on an interval and store it server-side (CheckMK's pull-agent logic). No new
   agent-side behavior is strictly required for this — the existing `GET /api/v1/metrics`
   bulk-dump endpoint (see below) is exactly the efficient pull path a Commander needs; `mode:
   satellite` in config.yaml is documentation of intent rather than a behavioral switch in v1.
3. **Proxy** (nicknamed **Selecta**, per the user) — an agent that itself pulls from a list of
   configured satellites (over TLS directly to each satellite's own REST port, see below) and
   stores their data alongside its own, so a Commander that can't reach every satellite directly
   (firewalled segments, distributed networks) can instead pull one aggregate feed from the proxy.
   From the Commander's point of view, pulling from a proxy looks identical to pulling from a
   single agent — just with more data, tagged by origin. The `mode: proxy` config value itself is
   unchanged; "Selecta" is branding for docs/README, not a technical rename.

**Bulk metrics endpoint (implemented, needed by all three modes):** `metrics_dump` (MCP tool)
and `GET /api/v1/metrics` (REST, note: no `{metric}` path segment — that continues to mean
"query one named metric") return *every* metric this agent has recorded in one call, keyed by
metric name. This is what makes efficient polling possible without a Commander needing to know
every metric name in advance — the single building block satellite-mode pulling and proxy-mode
aggregation both rely on. `internal/store.Store` gained `ListMetricNames` to support it.

**Proxy mode auth (implemented, revised twice after user feedback): TLS client certificates,
authorizing the *caller* — not a server-identity pin.** This went through two iterations before
landing on the confirmed design:
1. First pass: an SSH tunnel (rejected — the user meant the SSH *trust model*, not the protocol).
2. Second pass: the proxy pins the satellite's server public key (TLS, no CA, `VerifyPeerCertificate`)
   — built and verified, but the user then clarified the trust direction should be the other way
   round: **the caller (a Fleet Commander, or a proxy acting on its behalf) holds a private key;
   every node agent it wants to reach holds that caller's public key and uses it to authorize
   access to REST/MCP.** This is now the implemented design.

Confirmed scope (via follow-up questions): only the client-authentication direction is checked —
satellites do **not** pin the caller's server key in return (accepted trade-off: a compromised
network path could still impersonate a satellite to a proxy, since `InsecureSkipVerify` disables
the proxy's server-identity check entirely — mitigated by the fact that the interesting data flow,
metrics being read, requires no write access and the response is HTTP GET-only). Client-cert
authorization is checked **in addition to**, not instead of, the existing bearer token. And it is
implemented as a **general REST/MCP authorization mechanism**, not proxy-specific: any node agent
can configure `tls.trusted_client_keys`, and any caller presenting a matching client certificate
(a Fleet Commander connecting directly in satellite mode, or a proxy pulling from a satellite)
gets past the gate — the SSH `authorized_keys` model, over TLS.

Implementation:
- **Server side (`config.TLS.TrustedClientKeys`, any agent):** each entry is `{name,
  public_key_path}` — a PEM-encoded PKIX public key extracted from an authorized caller's client
  certificate (e.g. via `openssl x509 -pubkey -noout`), distributed out of band. When non-empty,
  `Config.Validate` requires `tls.enabled`. `cmd/agentic-mcpd/http.go`'s `serveHTTP` sets
  `tls.Config.ClientAuth: tls.RequestClientCert` (requested, not required, at the transport level
  — so PAM-login browser access to `/ui/` keeps working without a client cert) and wraps only
  `/mcp` and `/api/v1/` with `requireTrustedClientCert`, an application-layer gate that 401s
  unless `r.TLS.PeerCertificates[0]`'s public key matches one of the loaded trusted keys
  (`internal/tlsauth.MatchesAny`, comparing DER-encoded SubjectPublicKeyInfo). `/healthz` and
  `/ui/` are unaffected either way.
- **Client side (`config.Proxy.ClientCertFile`/`ClientKeyFile`, proxy mode):** the proxy's own
  TLS client identity, loaded once at startup (`fleet.LoadClientCert`) and presented via
  `tls.Config.Certificates` on every request `fleet.Puller.PullOnce` makes. `config.Satellite`
  dropped the earlier `public_key_path` field entirely (no more server-key pinning); a satellite
  entry is now just `{name, address, token, poll_interval}`. `Config.Validate` requires
  `proxy.client_cert_file`/`client_key_file` whenever `mode: proxy`.
- **New package `internal/tlsauth`:** `LoadTrustedKey(name, path)` and `MatchesAny(cert, keys)` —
  shared, independently unit-tested logic for the authorized-keys-style comparison, used by
  `cmd/agentic-mcpd/http.go`'s gate.

Confirmed design points (unchanged from the original discussion):
- **Pull, not push** — the proxy initiates; satellites need no knowledge of the proxy beyond its
  pinned public key.
- **Full history relayed** — every point the proxy pulls from a satellite is written into the
  proxy's *own* `internal/store`, labeled with the satellite's identity (`{"satellite": "<name>"}`
  merged into each point's existing labels), so the proxy's retention/downsampling job (already
  built in step 6) applies to satellite data too, and a Commander pulling from the proxy sees the
  same time resolution it would from a direct connection.

**Verification (real, end to end, on `host1.example.internal`):** two independent
`agentic-mcpd` processes were run as genuinely separate satellite and proxy instances.
- Satellite: `mode: standalone`, `tls.enabled: true` with its own self-signed server cert
  (unrelated to the client-auth mechanism) plus `tls.trusted_client_keys` pinning the proxy's
  client public key (copied out to simulate out-of-band distribution).
- Proxy: `mode: proxy`, `proxy.client_cert_file`/`client_key_file` pointing at its own freshly
  generated ECDSA client certificate, one satellite entry at `127.0.0.1:8030`, `poll_interval: 5s`.
- **Direct HTTP verification before even starting the proxy daemon**, via `curl`: `/healthz`
  returns 200 with no client cert; `/api/v1/metrics` returns 401 with no client cert; `--cert
  --key` with the satellite's pinned proxy cert + correct bearer token returns 200; the same call
  with an unrelated, untrusted client cert returns 401 (`client certificate not trusted`) — proving
  the gate is enforced exactly where intended (`/api/v1/` protected, `/healthz` open) before any
  proxy-specific code even ran.
- **Full proxy loop:** confirmed via the proxy's own log and `GET /api/v1/metrics` on the proxy —
  the satellite's `agentic_mcpd_start` points arrived labeled `{"satellite": "sat-e2e"}` at the
  expected 5-second cadence (`satellite poll completed satellite=sat-e2e points=1`).
- **Negative case, also verified live (not just unit-tested):** a second, independent proxy
  process was started with an unrelated client certificate not in the satellite's trusted list.
  Its poll failed against the real satellite with `unexpected status 401: client certificate not
  trusted`, proving the rejection holds under genuine network traffic end to end, not just the
  in-process test harness or a bare `curl` call.
- Unit tests: `internal/tlsauth/tlsauth_test.go` covers key loading and matching in isolation;
  `internal/fleet/puller_test.go` covers the puller presenting its client cert against a real
  in-process TLS server configured with `ClientAuth: RequireAnyClientCert` (success, untrusted-cert
  rejection via a genuine TLS handshake failure, and missing-token rejection).

## Enrollment (`agentic-mcpd register`, implemented)

The three operating modes above rely on `tls.trusted_client_keys` being populated with a caller's
pinned public key — previously only achievable by manually copying a key file to every agent.
`agentic-mcpd register` is this agent's client-side half of a one-time bootstrap handshake that
automates it. It is deliberately generic: the same command works against **either** enrollment
authority in this project —

- a future central Fleet Commander ("Bossman," see the Roadmap), or
- a **Selecta** — a `mode: proxy` agent that itself accepts dynamically enrolled satellites (see
  "Selecta: dynamic satellite enrollment" below) —

since both speak the identical wire protocol defined here. A Duppy (standalone node agent) simply
points `register` at whichever one it's joining.

**Protocol:** `POST <enroll-url>/api/v1/enroll` with a JSON body `{name, enroll_secret, token,
address}` — `name` identifies this agent (defaults to its hostname), `enroll_secret` is a shared
bootstrap secret proving this agent is authorized to join (the only authentication possible before
any trust exists — no pinned key, no client cert yet), `token` is this agent's own existing
REST/MCP bearer token (so the enrolling authority knows how to call it back), `address` is
optionally this agent's own reachable `host:port`. A successful response is `{bossman_public_key,
agent_id}` — `bossman_public_key` (field name kept for wire compatibility regardless of which
authority answers) is the enroller's PEM-encoded PKIX public key, written to disk and referenced
from `tls.trusted_client_keys` so the enroller can subsequently authenticate itself over TLS client
certificates (see `internal/tlsauth`) exactly like a proxy talking to a satellite.

**Deliberately does not auto-edit config.yaml.** `register` writes the fetched public key to a
file (`--trusted-key-path`, default `/etc/agentic-mcp/trusted/enroller.pub.pem`) and prints the
`tls.trusted_client_keys` YAML snippet for the operator to add (pinned under `--key-name`, default
`enroller`) — round-tripping arbitrary hand-edited YAML while preserving comments/structure was
judged too risky for a first implementation; safer to have the operator (or a provisioning tool)
confirm the change explicitly.

**`--generate-token` is a separate, standalone flag**, not part of `register`: `agentic-mcpd
--generate-token` prints a fresh 32-byte (64 hex char) cryptographically random token via
`crypto/rand` and exits — for bootstrapping a new agent's own `config.yaml` token (or rotating an
existing one) independently of any enrollment interaction. `register` reads this token back out of
the already-loaded config rather than generating one inline, keeping the two concerns cleanly
separate as confirmed with the user.

**Implementation:** new `internal/enroll` package (`Register(ctx, enrollURL, Request) (Result,
error)`) does the HTTP POST/JSON exchange using the standard library's default TLS verification
(a normal CA-signed or pre-trusted cert on the enrollment endpoint — there's no pinned key to
verify against yet, since establishing one is the whole point of this call). `cmd/agentic-mcpd`
dispatches `os.Args[1] == "register"` to `runRegister` (its own flag set: `--enroll-url`,
`--enroll-secret`, `--name`, `--address`, `--config`, `--key-name`, `--trusted-key-path`) in
`cmd/agentic-mcpd/register.go`; `newBearerToken()` in the same file backs `--generate-token`.

**Verification:** `internal/enroll/enroll_test.go` covers success, wrong-secret rejection, an
empty-public-key response, an unreachable server, and a 500 whose message propagates into the
returned error — all against a real `httptest.Server`, not a mocked interface. End to end: a
minimal mock enrollment server (a ~30-line Python `http.server` implementing exactly the
`POST /api/v1/enroll` contract above) was run for real, and the actual `agentic-mcpd` binary was
invoked against it — `register` with the correct secret wrote a real key file to disk and printed
the correct config snippet; the same call with a wrong secret failed with the server's real 401
response propagated into the CLI's error message. `--generate-token` was run twice, confirmed to
produce distinct 64-character hex strings each time.

## Selecta: dynamic satellite enrollment (implemented)

`mode: proxy` (a Selecta) originally only polled the fixed list of satellites in its own
`config.yaml`'s `proxy.satellites` — adding or removing one required an edit + restart. A Selecta
now additionally accepts satellites enrolling themselves at runtime via the exact same
`agentic-mcpd register` command and `internal/enroll` wire protocol Bossman enrollment uses (see
above) — no second protocol was introduced, since the trust direction is identical: the entity
that will poll (the Selecta) needs its public key pinned by the entity it polls (the satellite),
which is exactly the enrollment handshake's shape.

**Config additions** (`internal/config`): `proxy.enroll_secret` — shared bootstrap secret; when
empty, `POST /api/v1/enroll` is not registered at all (enrollment stays off by default).
`proxy.satellites_path` — SQLite file backing the dynamic satellite registry, defaulting to
`/var/lib/agentic-mcp/satellites.db`. Validation no longer requires at least one static satellite
under `mode: proxy` — a Selecta with zero satellites configured up front (everything arrives via
enrollment) is now a valid, supported configuration; it still requires a client cert/key pair,
since that's the identity it presents when polling any satellite, static or dynamic.

**`internal/fleet.SatelliteRegistry`** (`registry.go`, new): a small SQLite-backed store — one
`satellites` table (`name` PK, `address`, `token`, `poll_interval_ns`, `created_at`) — with
`Add`/`Remove`/`List`. Poll interval is persisted as raw nanoseconds, not seconds: an early version
stored `int64(interval.Seconds())`, which silently truncated any sub-second interval to `0` and
fell back to the 1-minute default — caught by a real test using a 10ms interval, fixed by storing
`int64(interval)` directly.

**`internal/fleet.Manager`** (`manager.go`, new): reconciles the static `config.yaml` satellite
list with the dynamic registry and takes immediate effect on mutation — `Enroll`/`Remove` start or
cancel that satellite's polling goroutine right away, rather than waiting for a periodic
reconciliation pass or a restart. `Start` loads both static and dynamic satellites once at daemon
startup; re-enrolling a name that collides with a static entry cancels and restarts its poller
under the new parameters (same cancel-and-restart path used for any re-enrollment).

**Own public key without a second keypair:** a Selecta hands out its public key during enrollment
by extracting it directly from `proxy.client_cert_file` — the identity it already uses when
polling satellites — via the new `tlsauth.PublicKeyPEMFromCertFile(certFile string) ([]byte,
error)`, rather than minting an enrollment-specific keypair nobody else needs.

**REST surface** (`internal/server/enroll.go`, new), mounted only when `mode: proxy` and a
satellite manager exists:
- `POST /api/v1/enroll` — gated behind both `cfg.Write` and a non-empty `proxy.enroll_secret`;
  absent entirely (404, not 403) otherwise, so an unconfigured Selecta reveals nothing about
  whether enrollment could ever be turned on.
- `GET /api/v1/proxy/satellites` — lists currently polled satellites (static + dynamic).
- `DELETE /api/v1/proxy/satellites/{name}` — the requested "delete a satellite again" capability;
  gated behind `cfg.Write` like every other mutating route in this project; stops that satellite's
  poller immediately and removes it from the registry.

**`cmd/agentic-mcpd/main.go`** wiring: `startProxyManager` (opens the registry, loads the client
cert, starts the `Manager`) replaces the old one-ticker-per-satellite `startProxyPollLoop`;
`loadProxyPublicKeyOrWarn` reads the Selecta's own public key for the enrollment endpoint to hand
out, only when `proxy.enroll_secret` is actually set. Both degrade gracefully (log + continue
without satellite polling / without the enrollment endpoint) rather than failing the whole daemon,
consistent with every other optional subsystem here (eBPF, PAM).

**Verification:** `internal/fleet/registry_test.go` (8 tests) and `manager_test.go` (8 tests,
including a `fakePuller` test double and immediate start/stop-on-mutation coverage) unit-test the
registry and manager in isolation; `internal/server/enroll_test.go` (8 tests) covers the REST
layer including write-gate enforcement, wrong-secret rejection, and route absence outside proxy
mode; `internal/tlsauth/tlsauth_test.go` gained 3 tests for `PublicKeyPEMFromCertFile`, including a
round-trip through `LoadTrustedKey`/`MatchesAny` proving the extracted key is actually usable as a
pin, not just textually similar. `agentic-mcpd register` now uses generic `--enroll-url` (was
`--bossman-url`) and `--key-name` flags so the identical CLI command targets a Selecta or a future
Bossman.

**Real end-to-end verification** (two real `agentic-mcpd` binaries on
`host1.example.internal`, not mocked): a Selecta (`mode: proxy`, `write: true`,
`proxy.enroll_secret` set, `proxy.satellites: []` — zero satellites configured up front) and a
Duppy (`mode: standalone`, TLS enabled, empty `trusted_client_keys`) were started as separate
processes. `agentic-mcpd register --enroll-url http://<selecta>:8051 --enroll-secret ... --name
duppy1 --address 127.0.0.1:8052 --key-name selecta` was run for real against the Selecta:
- The call succeeded, printed `Registered "duppy1" ... (agent id: duppy1)`, and wrote the
  Selecta's real public key to disk.
- `GET /api/v1/proxy/satellites` on the Selecta immediately showed `duppy1` — proving `Enroll`
  takes effect without a restart.
- The Selecta's first poll tick (60s default, since enrolled satellites carry no
  `poll_interval`) **succeeded even before Duppy trusted the Selecta's certificate**
  (`satellite poll completed satellite=duppy1 points=1`) — confirming bearer-token auth alone is
  sufficient when `trusted_client_keys` is empty, and mTLS pinning is an additive, not required,
  layer (matches `internal/tlsauth`'s documented "empty list ⇒ no client-cert enforcement"
  behavior).
- The printed `tls.trusted_client_keys` snippet was then added to Duppy's config.yaml and Duppy
  was restarted; the Selecta's next poll tick still succeeded
  (`satellite poll completed satellite=duppy1 points=1`), confirming the Selecta's client
  certificate (the same one it hands out during enrollment) is genuinely accepted under full mTLS
  enforcement, not just coincidentally matching by bearer token.
- `DELETE /api/v1/proxy/satellites/duppy1` returned `{"name":"duppy1","removed":true}`;
  `GET /api/v1/proxy/satellites` immediately showed `{"satellites":null}`; and — checked over the
  next full poll interval, not just the list view — the Selecta's log gained **zero** further
  "satellite poll" lines for `duppy1`, confirming the poller goroutine was actually cancelled, not
  merely hidden from the list.
- Test processes and directories were removed from the test host afterward.

## File upload (staging)

A gap identified while designing the README/multi-orchestrator-compatibility work: none of the
existing modules can get a *new* file (a config file, a `.deb` package, a binary artifact) onto
the managed host in the first place. `copy` can write inline text content or copy a file that
already exists on the host; `file`/`slurp` manage/read existing paths. There was no ingestion path
for content that doesn't yet exist on the target machine.

**Sizing constraint that shapes the design:** the largest realistic artifact is a kernel package —
up to 274 MiB. That rules out base64 for the bulk path entirely: base64 costs ~33% more data
(274 MiB → ~365 MiB) and CPU to en-/decode, for no benefit — an HTTP request body is already
binary-safe; base64 only earns its keep when the transport *forces* text (like a JSON/MCP tool-call
argument).

**Why that distinction matters specifically for an LLM-driven MCP client:** when a plain REST/script
client calls an API, bytes flow straight from disk to socket. But when an LLM-driven MCP client
(Claude Code/Desktop) calls a tool, the model itself has to *generate* the tool-call arguments as
part of its own output, token by token. A base64 string for a 1 MB file is roughly 300–400k output
tokens — far beyond what a single response turn typically allows (commonly 4k–64k). A plain REST
caller (a script, or the future Fleet Commander) doesn't hit this limit, because those bytes never
pass through the model's generation loop.

**Design, accordingly two paths:**
1. **MCP tool `upload_file`** (small, base64, capped around 64 KB) — for content an AI would
   plausibly compose/edit itself (a config snippet, a small script). Parameters: a destination
   filename (name only, no path) and `content_base64`. Always writes into a fixed staging directory
   (`uploads_dir`, e.g. `/var/lib/agentic-mcp/uploads/`) — never an arbitrary destination path;
   ownership/mode/final placement stays the `copy` module's job (reusing its existing `check_mode`,
   write-gate, ACL, and audit wiring rather than duplicating it).
2. **REST endpoint `PUT /api/v1/upload?name=<filename>`** — no multipart, no base64: the entire
   request body *is* the raw file (`Content-Type: application/octet-stream`), e.g.
   `curl -T kernel-package.deb "https://host/api/v1/upload?name=kernel-package.deb"`. The server
   streams the body directly (`io.Copy` against an `io.LimitReader` bounded by `max_upload_size`) —
   the full 274 MiB is never buffered in memory. It's written to a temp file in the same staging
   directory first, then atomically renamed (`os.Rename`) into place once the copy completes fully,
   so an interrupted transfer never leaves a half-written file behind. Meant for a script or the
   future Fleet Commander ("Bossman") to call directly, not for an AI to generate.
3. Both paths go through the same **write gate** (`config.write: true` required, otherwise not
   registered/403) and **ACL** as every other write tool, and are recorded in the **audit log** —
   no bypass of the existing security architecture.
4. After upload, the caller uses the existing `copy` module with `src:
   /var/lib/agentic-mcp/uploads/<name>` and `dest: <target path>` to place the file at its final
   destination with the right owner/group/mode — upload handles transport only, `copy` handles
   placement (with its own `check_mode` preview and idempotency).

**Implemented.** New `internal/upload` package (`ValidateFilename`, `WriteStaged`) holds the shared
staging logic used by both paths — filename validation rejects empty names, path separators, and
`.`/`..`; `WriteStaged` streams into a temp file via `io.CopyN` against `maxSize+1` (so exceeding
the limit is detected without ever buffering the full oversized body) and only `os.Rename`s into
place once the copy fully succeeds, cleaning up the temp file on any failure path. `config.Config`
gained `UploadsDir` (default `/var/lib/agentic-mcp/uploads`) and `MaxUploadSize` (default 512 MiB,
comfortably above the 274 MiB kernel-package case), both validated in `Config.Validate`.
`internal/server/upload.go` wires the MCP tool (`RegisterUploadFile`, write-gated, ACL- and
audit-wrapped exactly like every other write tool, capped at `maxMCPUploadBytes` = 64 KiB
independent of `MaxUploadSize`) and the REST handler (`PUT /api/v1/upload?name=...`, with an early
413 when `Content-Length` alone already exceeds the limit, before streaming even starts).

**Verified:**
- Unit tests (`internal/upload/upload_test.go`, 8 cases): filename validation table, successful
  write, directory auto-creation, overwrite idempotency (with a check that no stray temp files are
  left behind), path-traversal rejection, size-limit enforcement at and past the boundary, and —
  using a `Reader` that fails mid-stream — confirmation that an interrupted transfer leaves no
  partial file in the staging directory at all.
- REST + MCP tests (`internal/server/upload_test.go`, 12 cases): success, write-gate 403, ACL 403,
  path-traversal rejection, size-limit rejection (both the streamed-body case and the
  fast `Content-Length` pre-check), overwrite idempotency, tool-not-registered-when-write-false,
  invalid-base64 rejection, and the 64 KiB MCP cap.
- **Real, end to end:** a live daemon (`write: true`, `max_upload_size: 64MiB`) received a genuine
  5 MiB random binary via `curl -T ... PUT /api/v1/upload` — `cmp` confirmed the staged file was
  byte-identical to the source. The same daemon correctly returned 401 with no bearer token, 422
  for a `../../etc/evil` path-traversal attempt (with no file appearing outside the staging
  directory), and 413 when the upload exceeded a deliberately small `max_upload_size` (1 MiB
  against a 5 MiB body). Separately, the real `claude` CLI was connected to the daemon as a
  genuine MCP client (`claude mcp add --transport http`) and asked to call `upload_file` directly
  — the tool call succeeded and the staged file's content matched exactly what was requested.

## Write-error propagation audit

Prompted by a direct question: does every write call actually surface a non-2xx status/MCP error
on failure, or could any silently report success? A full pass across every write module and both
access layers found the propagation code itself already correct everywhere — but two write
modules (`apt`, `systemd`) and one (`copy`) had no automated test proving it, so a real failure
regressing to a false "success" would have gone unnoticed.

**What was checked:** all 6 write modules (`file`, `copy`, `lineinfile`, `systemd`/`service`,
`apt`, `command`), the MCP wrapping layer (`registerModuleTool`, `registerTaskTool`,
`RegisterRunPipeline`, `RegisterUploadFile` in `internal/server`), the REST wrapping layer
(`handleToolCall`'s three branches, the ACL admin endpoints, `handleUpload`), and
`internal/pipeline.Run`. Every one of these correctly returns/propagates a non-nil `error` on
failure, which both `mcp.AddTool`'s handler contract (returning a non-nil error sets
`CallToolResult.IsError = true`) and every REST handler (`writeError(w, <non-2xx>, err)`) turn
into a caller-visible failure. `writeError` always requires an explicit status code argument —
there is no code path that can fall through to a default 200.

One deliberate, documented exception: `command`'s and the pipeline's non-zero *exit code* is
data, not a Go error (`data.rc`/`exit_code` in the result) — matching `ansible.builtin.command`'s
own behavior, where a non-zero return code doesn't fail the task unless the caller checks it.
This is intentional, not a gap, and is called out in both modules' tool descriptions.

**Gap found and fixed:** `apt` and `systemd` had tests for every idempotency/dry-run/invalid-input
path but none for "the underlying `apt-get`/`systemctl` command itself fails" (e.g. a broken
package, a unit that fails to start) — a real regression there (e.g. someone changing `Run` to
ignore the runner's returned error) would have passed the existing suite. `copy` was similarly
missing coverage for a missing `src` file and an unwritable `dest`. Added:
`TestApt_InstallFailurePropagatesError`, `TestApt_UpdateCacheFailurePropagatesError`,
`TestSystemd_ActionFailurePropagatesError`, `TestSystemd_EnableFailurePropagatesError`,
`TestCopy_MissingSrcPropagatesError`, `TestCopy_UnwritableDestPropagatesError` — each constructs a
fake `CommandRunner` (or, for copy, a real missing/unwritable path) that fails the way the real
tool would, and asserts `Run` returns a non-nil error.

**Verified live, not just unit-tested:** against a real running daemon (`write: true`), REST calls
were made with inputs guaranteed to fail for real — `systemd` restarting a unit that doesn't exist,
`copy` writing into a nonexistent parent directory, and `apt` installing a package that doesn't
exist. All three returned HTTP 422 with the real underlying error message (including apt-get's
actual exit code 100 for "unable to locate package" — genuine system tool failure, not a
simulated one). The same `systemd` failure was also called through a real MCP session (the
`claude` CLI connected as a genuine MCP client) and confirmed to come back with `isError: true`
and the same error message.

**Follow-up fix (same audit, one more turn): the exit code alone still wasn't enough.** The
initial audit confirmed every failure surfaces *an* error, but the error text for anything routed
through `internal/modules.CommandRunner` (`apt`, `systemd`, and every future runner-based module)
was just `"<cmd>: exit status N"` — no indication of *why*. An AI deciding what to do next needs
the real reason ("Unit not found" vs "permission denied" vs "dependency failed"), not just a
number. `defaultCommandRunner` (`internal/modules/runner.go`) now wraps a failing command's error
with its actual stderr text via `wrapExitError` — `cmd.Output()` already populates
`exec.ExitError.Stderr` whenever `cmd.Stderr` is left nil, so this required no new capture
plumbing, just surfacing what was already collected. Re-running the exact same live failures above
confirms the difference: the `systemd` case now reads `"...exit status 1: Failed to restart
this-unit-definitely-does-not-exist.service: Die Wartezeit für die Verbindung ist abgelaufen"`
(a timeout, not a missing unit — the real reason) instead of the bare exit code, and `apt` now
surfaces the actual dpkg lock/permission error instead of just "exit status 100".

The same gap existed in `internal/pipeline.Run`: `Result` only ever exposed the *last* stage's
stderr, so `failing-stage | trivially-successful-stage` (e.g. `ls <missing> | cat`) would report
overall success with zero visibility into why the first stage didn't do what was expected.
`Result` gained a `Stages []StageResult` field (`{cmd, exit_code, stderr}` per stage) alongside the
existing last-stage-mirroring `Stdout`/`Stderr`/`ExitCode` fields (kept for backward compatibility).

Verified: `internal/modules/runner_test.go` (new) covers a real failing command's error including
its actual (locale-independent-asserted) stderr text, a clean success path, and a missing-binary
error. `internal/pipeline/exec_test.go` gained `TestRun_EarlierStageFailureVisibleInStages`,
constructing exactly the `ls <missing> | cat` scenario above and asserting stage 0's real exit code
and stderr both survive in `Result.Stages` even though the pipeline "succeeds" overall.

## `ansible.builtin` module coverage plan

Prompted by the real count from `ansible-doc -l` (71 modules in `ansible.builtin` on the local
core 2.16.3 install — matches the ballpark "~74" the user cited). Not all 71 are in scope:

- **~19 controller-side directives excluded entirely** — `add_host`, `assert`, `async_status`,
  `debug`, `fail`, `gather_facts` (meta-alias of `setup`, already covered), `group_by`,
  `import_playbook`, `import_role`, `import_tasks`, `include_role`, `include_tasks`,
  `include_vars`, `meta`, `pause`, `set_fact`, `set_stats`, `validate_argument_spec`,
  `wait_for_connection`. These are Ansible-*controller*-side constructs (control flow, variable/
  inventory manipulation on the machine running Ansible itself) with no corresponding action a
  node agent executes on a managed host — implementing them would be building the wrong thing.
  Confirmed with the user.
- **Both package-manager families in scope** (confirmed with the user, not Debian-only): the
  existing `apt` module's Debian-family siblings (`apt_key`, `apt_repository`,
  `deb822_repository`, `dpkg_selections`) *and* the RedHat family (`yum`, `yum_repository`,
  `dnf`, `dnf5`, `rpm_key`) — the latter unit-tested only (fake `CommandRunner`, matching the
  existing `apt`/`systemd` test pattern) since the project's real test host
  (`host1.example.internal`) is Debian 13, not a RedHat-family distro.
- **Real remaining scope: ~28 modules**, genuine host-management actions that fit this project's
  existing `Module` interface pattern: `blockinfile`, `replace`, `template`, `get_url`,
  `hostname`, `timezone`, `cron`, `user`, `group`, `tempfile`, `unarchive`, `script`, `expect`,
  `git`, `subversion`, `pip`, `package`, `systemd_service` (alias of `systemd`, like `service`
  already is), `sysvinit`, `wait_for`, `uri`, `known_hosts`, `iptables`, `reboot`, `fetch`,
  `assemble`, `debconf`, `ping`.

**Batching, per the user's explicit direction** ("in Batches nacheinander, jeweils testen und
committen"): work through in groups, testing and committing each before starting the next —
Batch 1 (text/file), Batch 2 (system/user identity), Batch 3 (Debian packaging), Batch 4 (RedHat
packaging), Batch 5 (network/download), Batch 6 (everything else). Real end-to-end verification
uses `host1.example.internal` (user `marvin`, key `~/.ssh/marvin.key`, passwordless sudo) —
the user explicitly offered this host for the batch work.

### Batch 1 — text/file modules (implemented): blockinfile, replace, assemble, tempfile, template

All five follow the existing `Module` interface exactly (idempotent, `check_mode` via
`dry_run`, cross-tool-equivalents description, registered in
`server.NewDefaultModuleRegistry` gated by the write flag like every other write module).

- **`blockinfile`** — insert/update/remove a marker-comment-delimited block, identified by its
  `# BEGIN/END ANSIBLE MANAGED BLOCK`-style markers so re-running with different content replaces
  the block in place rather than duplicating it. Missing markers → append at EOF. A documented
  subset of the real module (no `insertafter`/`insertbefore`/`backup`).
- **`replace`** — regex find-and-replace across a whole file's content (not line-scoped like
  `lineinfile`), Go RE2 syntax with `$1`-style backreferences (Ansible's own `replace` uses Python
  `\1` syntax — a real, documented syntax difference, not a bug).
- **`assemble`** — concatenates every file in a source directory (sorted by name, optional
  filename-regexp filter, optional delimiter) into a single destination file — the classic
  `conf.d/*.conf` → one real config file pattern. Reuses `applyOwnerGroupMode` (already built for
  `file`/`copy`) for the destination's owner/group/mode.
- **`tempfile`** — creates a uniquely-named temp file/directory and returns its path. Deliberately
  *not* idempotent (like `mktemp`, every real call creates something new and reports
  `changed=true`) — documented as an intentional exception to the idempotency pattern the rest of
  the module set follows, the same way `command`'s non-zero-exit-isn't-an-error is a documented
  exception.
- **`template`** — renders `{{ variable }}` placeholders against a `vars` map. Explicitly *not* a
  Jinja2 implementation: Ansible's `template` module is full Jinja2 (filters/conditionals/loops/
  macros); reimplementing that is out of scope, so this covers plain variable substitution only,
  reusing the exact `{{ }}` placeholder convention this project's own `tools.d` task definitions
  already use (`internal/tasks`) rather than introducing a second templating syntax. A referenced
  placeholder with no matching `vars` entry is a hard error, not a silently-blank substitution.

**Verified:** 32 new unit tests across the five modules (idempotency, dry-run, error paths —
missing src, invalid regexp/marker, missing template var — and the `blockinfile`/`assemble`/
`template` marker/sort-order/placeholder logic specifically). All five also run for real on
`host1.example.internal`: `blockinfile` inserted a real marked block into a scratch file and
was confirmed idempotent on a second identical call; `replace` real-edited that file's content;
`assemble` concatenated two real fragment files in `/tmp/confd` into one destination; `tempfile`
created a real file under `/tmp` with the requested prefix/suffix; `template` rendered real
`{{ host }}`/`{{ port }}` placeholders to disk — all via genuine REST calls against the compiled
binary, not mocks.

### Batch 2 — system/user identity modules (implemented): user, group, cron, hostname, timezone

- **`group`** — ensures a system group's existence/gid via `getent group` (check) +
  `groupadd`/`groupmod`/`groupdel` (apply).
- **`user`** — ensures a system account's existence/uid/primary group/shell/home/comment/
  secondary groups via `getent passwd` + `id -Gn` (check) + `useradd`/`usermod`/`userdel`
  (apply). Secondary `groups` supports both replace (default) and `append=true` modes, each
  computed against the account's *actual* current secondary groups (via `id -Gn`) so an
  append-mode call is genuinely idempotent once the group is already present, not just
  unconditionally re-running `usermod -aG`. Password/credential management is deliberately out
  of scope — setting a hash through a tool call that ends up in the audit log was judged the
  wrong shape for that concern.
- **`cron`** — present/absent crontab entries identified by a `#Ansible: <name>` marker comment
  (Ansible's own convention), so changing a schedule or command later replaces the same entry
  rather than appending a duplicate. `crontab -l` for a user with no crontab yet is treated as an
  empty crontab, not an error (matching real `crontab`'s own behavior). Writing uses `crontab
  -u <user> <tempfile>` — `crontab` accepts a filename argument directly, so no stdin-piping
  plumbing was needed in `CommandRunner`.
- **`hostname`** / **`timezone`** — systemd-only (`hostnamectl`/`timedatectl`), matching this
  project's existing systemd-only scope (see `service`/`systemd`). Both read their current value
  without shelling out — `hostname` via `os.Hostname()`, `timezone` by resolving `/etc/localtime`'s
  symlink target and extracting the suffix after `zoneinfo/` (works whether the link is absolute
  or the relative form `../usr/share/zoneinfo/...` that `timedatectl` actually produces in
  practice — confirmed during live verification below).

**Verified:** 44 new unit tests (idempotency including the append-mode secondary-groups case,
dry-run, invalid state, and failure-propagation for every runner-backed module). All five also run
for real, as root, on `host1.example.internal`: created a real `batch2testgroup`/
`batch2testuser` pair (confirmed idempotent on a repeat call), added and then rescheduled a real
crontab entry for that user (confirmed the marker-based replace-in-place behavior, and that a
brand-new user's "no crontab for X" is handled as empty rather than an error), changed the box's
real hostname and timezone away from and back to their original values (`host1.example.internal`
/ `Europe/Berlin`) with idempotent no-op calls confirmed at each starting point, and finally
removed the test user/group again via the modules' own `state: absent` path.

### Batch 3 — Debian packaging modules (implemented): apt_key, apt_repository, deb822_repository, dpkg_selections

- **`apt_repository`** — present/absent one-line `deb ...` entries in a specific
  `/etc/apt/sources.list.d/<filename>.list` file. `filename` is required (a focused subset —
  Ansible auto-derives a default from the repo string via its own heuristic; requiring it keeps
  behavior simple and predictable), and `state: absent` only searches that one file rather than
  every configured source file. Optional `update_cache` runs `apt-get update` afterward.
- **`deb822_repository`** — present/absent modern RFC822-style (`.sources`) stanzas, the format
  apt 2.4+ (Debian 12+/Ubuntu 24.04+) uses in place of the older one-line syntax. Covers
  types/uris/suites/components/signed_by (a focused subset of the real module's many optional
  per-field options).
- **`apt_key`** — implemented via `gpg --dearmor` writing straight to
  `/etc/apt/trusted.gpg.d/<id>.gpg`, **not** the `apt-key` binary itself, which upstream Debian/
  Ubuntu have deprecated and removed from newer releases (real Ansible's own `apt_key` module is
  itself marked deprecated for the same reason) — this is the same replacement approach Debian's
  release notes recommend. Accepts the key as inline `data` or fetched from a `url` (a small
  injectable `HTTPGet` using Go's own `net/http`, no external download tool needed).
- **`dpkg_selections`** — sets a package's dpkg selection (most commonly `hold`, to freeze it
  against future apt upgrades) via `dpkg --get-selections`/`--set-selections`. This is the first
  module needing stdin (`dpkg --set-selections` has no file-argument alternative, unlike
  `crontab`), so `internal/modules/runner.go` gained a `CommandRunnerWithStdin` /
  `defaultCommandRunnerWithStdin` counterpart to `CommandRunner` — reused immediately by `apt_key`
  for `gpg --dearmor`, which also only accepts its input via stdin.

**Also fixed while implementing this batch:** a systematic re-check of every enum-shaped
parameter across all modules turned up two that declared a JSON-schema `enum` for MCP clients but
never actually validated it in Go — `dpkg_selections`'s `selection` and `cron`'s `special_time`.
Both now reject an out-of-range value explicitly instead of silently passing it through to the
underlying command (which would likely have failed anyway, but with a much less clear error).

**Verified:** 42 new unit tests, including a genuine `gpg`-binary integration test for `apt_key`
(`TestAptKey_RealGPGDearmor`: generates a real throwaway Ed25519 key via `gpg --quick-generate-key`
in an isolated `GNUPGHOME`, exports it armored, dearmors it through the actual module code, and
confirms the output is real binary OpenPGP data, not the fake/simulated transform the other tests
use). All four also run for real on `host1.example.internal`: created and removed a real
`apt_repository` entry and a real `deb822_repository` stanza; generated a genuine GPG key on the
host, imported it via `apt_key`, and confirmed with `file` that the written keyring is real OpenPGP
data — then removed it; and toggled the real, already-installed `bash` package's dpkg selection to
`hold` and back to `install`, confirming both the change and the idempotent no-op with `dpkg
--get-selections` at each step.

### Batch 4 — RedHat packaging modules (implemented, unit-tested only): yum, dnf, dnf5, yum_repository, rpm_key

Per the confirmed scope (both package-manager families in coverage, not just Debian): this batch
has **no real end-to-end verification** — `host1.example.internal`, this project's only
real test host, is Debian 13, not a RedHat-family distro, so there is nowhere to run these against
a genuine `yum`/`dnf`/`rpm` toolchain. Each module's doc comment and description say so explicitly,
mirroring how `command`'s non-zero-exit-isn't-an-error and `tempfile`'s not-idempotent-by-design
are called out as deliberate, documented departures from the rest of the module set's guarantees.

- **`yum` / `dnf` / `dnf5`** — share a single implementation (`internal/modules/rpm_pkg.go`'s
  unexported `rpmPackageManager`, parameterized by binary name), since all three expose
  essentially the same install/remove/update CLI surface for the common case; `Yum`/`Dnf`/`Dnf5`
  are thin wrappers each supplying their own `Name()`/`Description()`. Presence is checked via the
  shared `rpm` database (`rpm -q --queryformat`) rather than the frontend binary, since all three
  ultimately record installs there regardless of which one performed them. For `state: latest`,
  `dry_run` against an already-installed package conservatively predicts `changed: true` — genuine
  certainty would need a real repository query, which isn't worth the complexity for a family this
  project can't verify end to end; a real (non-dry-run) call instead compares the installed
  version before and after running `update`, so `changed` reflects what actually happened rather
  than a guess.
- **`yum_repository`** — present/absent INI-style `.repo` stanzas in `/etc/yum.repos.d/`, the
  RedHat-family analogue of `apt_repository`. Same injectable-directory pattern for testability
  without root.
- **`rpm_key`** — `rpm --import`/`rpm -e` (rpm's own current, non-deprecated tools for this,
  unlike `apt_key`'s workaround for the deprecated `apt-key`). Presence is checked via `rpm -qa
  "gpg-pubkey-<keyid>-*"`, matching how rpm actually stores imported keys as
  `gpg-pubkey-<last-8-hex-of-fingerprint>-<date>` pseudo-packages — a glob query since the date
  suffix isn't known in advance, then the exact matched package name is used for removal (`rpm -e`
  needs an exact NVR).

**Verified:** 41 new unit tests. The `yum`/`dnf`/`dnf5` suite (`rpm_pkg_test.go`) is written once
against an `rpmModule` interface and table-driven over all three real `Module` implementations —
not just the shared core — so each concrete type is genuinely exercised, including present/absent/
latest transitions, the before/after version-comparison logic, dry-run, and failure propagation.

### Batch 5 — network/download modules (implemented): get_url, uri, wait_for, fetch, known_hosts, iptables

- **`fetch`** — a thin alias over `slurp` (same underlying `Run`, different parameter name
  `src` vs. `path`). Real Ansible's `fetch` copies a file *from* the managed host *to* the
  separate machine running Ansible; this agent has no such separate control-node filesystem (it
  *is* both ends), so fetching and slurping a file's content are the same operation here — no
  point building two things that behave identically.
- **`get_url`** — downloads a file, deliberately matching real Ansible's *conservative*
  idempotency rather than a naive "always check": if `dest` already exists, it's left alone
  entirely unless `force: true` or a `checksum` is given that doesn't match — no HEAD request or
  hash comparison "just to check" when neither was asked for, avoiding needless network traffic
  for a file presumably already correct.
- **`uri`** — an arbitrary HTTP request tool, deliberately **write-gated regardless of method**.
  `method` is a runtime parameter (GET vs. POST/PUT/DELETE/...), and this tool can reach and
  mutate arbitrary remote systems; trusting the caller's stated method to decide the write gate
  would mean a write:false agent still has an SSRF-shaped hole for anyone routing a mutating
  request through what looks like a "read" tool. Uniformly gating it, even for plain GETs, is the
  conservative default here.
- **`wait_for`** — polls a TCP port or file for a state transition. Read-only (never mutates
  system state, so it isn't write-gated) but capped at a 600-second maximum timeout regardless of
  the requested value, so a single tool call can't be used to tie up server resources indefinitely.
- **`known_hosts`** — present/absent SSH known_hosts entries, identified by hostname (the entry's
  first field) so a changed host key replaces the same entry rather than accumulating stale
  duplicates. Host-key hashing (`ssh-keygen -H` style) is not implemented — entries are always
  written in plain hostname form.
- **`iptables`** — present/absent netfilter rules, idempotent via `iptables -C` (the check flag
  purpose-built for exactly this: exit 0 means the exact rule exists, exit 1 means it doesn't — a
  normal negative result, not an error; anything else is a genuine failure). A focused subset of
  real Ansible's ~40 parameters (protocol/source/destination/ports/interfaces/jump/comment cover
  the common case).

**Verified:** 47 new unit tests (including `TestWaitFor_RealPortDetection`, exercising a real
`net.Listen`-backed TCP listener rather than a fake dialer, and the `uri` suite running against
real `httptest.Server` instances rather than mocked HTTP). All six also run for real on
`host1.example.internal`. `fetch`/`wait_for`/`known_hosts` ran directly: `fetch` read a real
`/etc/hostname`; `wait_for` confirmed the daemon's own real listening port; `known_hosts` wrote and
read back a real entry. `get_url`/`uri` needed a workaround — the test host turned out to have no
outbound internet access (an isolated test network), so a real local Python `http.server` was
started on the host itself as a genuine, independently-reachable HTTP endpoint: `get_url`
downloaded from it (confirmed idempotent on a repeat call, and confirmed a `sha256:` checksum
verifies correctly against a real download), and `uri` performed a real GET with real response
headers and a real 404 correctly rejected as not in the default `status_code` allow-list.
`iptables` was verified most carefully, given the blast radius of a mistake: a brand-new, entirely
unreferenced custom chain (`BATCH5TEST`, "0 references" the whole time, confirmed via `iptables -L
-v`) was created first so the test rule could never affect real traffic; the module added a rule
with the exact expected match criteria (`tcp dpt:12345`, the given comment) and packet counters at
zero, confirmed idempotent on a repeat call, removed the rule, and the custom chain itself was then
deleted — `INPUT`/`OUTPUT`/`FORWARD` were never touched.

### Batch 6 — everything else (implemented): ping, systemd_service, package, script, git, unarchive, pip, debconf, sysvinit, subversion, expect, reboot

The final batch, completing the confirmed `ansible.builtin` coverage scope from the plan above.

- **`ping`** — trivial `{"ping": "pong"}`, read-only, no parameters; the connectivity-check
  module every Ansible inventory implicitly relies on.
- **`systemd_service`** — a second alias over the same `Systemd` implementation as `service`,
  under Ansible's systemd-specific module name.
- **`package`** — an OS-family-agnostic dispatcher: detects the available package manager
  (`apt-get` → `dnf` → `dnf5` → `yum`, in that order, via an injectable `LookPath`) and delegates
  to the already-implemented Apt/Dnf/Dnf5/Yum module for that backend, so callers that don't want
  to name a specific package manager get one call that works on either family.
- **`script`** — a thin wrapper over `command`: splits `cmd` into argv and delegates. Real
  Ansible's `script` copies a file from the control node to the managed host before running it;
  this agent has no separate control-node filesystem (it *is* both ends), so this reduces to
  running an already-present executable, the same operation `command` performs — `script` exists
  purely for drop-in familiarity with real Ansible task syntax that names it explicitly.
- **`git`** — clone/checkout to a desired branch/tag/commit, idempotent via comparing
  `git rev-parse HEAD` before and after. A real correctness bug was caught and fixed while
  writing the end-to-end test: `git checkout <branch>` right after `git fetch origin` is a no-op
  when `<branch>` is already checked out locally — fetch only advances the remote-tracking ref
  (`origin/<branch>`), never the local branch pointer, so the original implementation would have
  silently never applied upstream updates to a tracked branch, defeating the module's entire
  purpose. Fixed by resolving to `origin/<version>` (a detached HEAD at the exact fetched commit)
  whenever that remote-tracking ref exists via `git rev-parse --verify`, falling back to the
  literal `version` for tags/commits, which have no `origin/` form.
- **`unarchive`** — extracts `.zip`/`.tar`/`.tar.gz`/`.tgz`/`.tar.bz2` archives already on the
  host, via Go's standard library `archive/zip`/`archive/tar`/`compress/gzip`/`compress/bzip2` —
  no external `tar`/`unzip` binary needed. Every archive member's target path is checked against
  a `../`-escape guard (`safeJoin`) before being written, so a hostile or malformed archive can't
  write outside the requested destination. Idempotency relies on `creates`, the same practical
  limitation real Ansible has without a working `creates` check: without it, every call extracts.
- **`pip`** — Python package presence/absence/latest via `pip show`/`pip install`/`pip
  uninstall`, with an optional `virtualenv` path created via `python3 -m venv` on demand (then
  that venv's own pip is used instead of a system-wide one). `state=latest` always attempts
  `pip install --upgrade` and determines `changed` from the version actually observed before vs.
  after, the same before/after-comparison approach `yum`/`dnf`'s `state=latest` uses.
- **`debconf`** — sets a single debconf database value via `debconf-set-selections`, idempotent
  against `debconf-show`'s current value; an optional `unseen` flag also clears the question's
  "seen" bit via `debconf-communicate` so a package will prompt for it again if reconfigured.
- **`sysvinit`** — the legacy-init counterpart to `systemd`/`service`, for hosts or individual
  services still on `/etc/init.d` scripts. Running state is checked via the init script's own
  `status` action (LSB convention: exit 0 means running); enabled-at-boot state is checked by
  globbing for an `S##<name>` symlink across the standard runlevel directories, and toggled via
  `update-rc.d enable`/`disable`.
- **`subversion`** — checkout/update a working copy to a desired revision, idempotent via
  comparing `svn info`'s `Revision:` before and after — the same shape as `git`, but without
  `git`'s local-branch-vs-remote-tracking-ref complication (svn has no local commits to conflict
  with an update).
- **`expect`** — runs a command and answers interactive prompts via a `responses` map (regex →
  answer), each firing at most once as soon as its pattern matches the accumulated output.
  **Stated limitation:** this pipes stdout/stderr rather than allocating a real pseudo-terminal,
  unlike Ansible's own `pexpect`-based implementation, so programs that specifically need tty
  semantics (echo suppression, terminal-size queries, raw mode) may not behave correctly — suited
  to straightforward line-buffered prompts, not full terminal emulation. The core prompt-matching
  logic (`firstUnansweredMatch`) is factored out and unit-tested independent of process spawning;
  a real end-to-end test additionally spawns a genuine shell script with a real `read` prompt to
  confirm the poll/match/write-to-stdin loop actually works against a real process.
- **`reboot`** — issues `shutdown -r now` and returns immediately. **Stated architectural
  limitation:** real Ansible's `reboot` module runs from a separate control node over SSH and can
  therefore poll the target until it reappears before reporting success; this agent runs *on* the
  host being rebooted, so the process handling the call is terminated the moment the reboot
  happens — there is no possibility of waiting for the host to come back up from inside itself.
  Verifying the host actually returns is the caller's responsibility (e.g. a later call, from a
  new connection, to `wait_for` or `ping`).

**Verified:** 50 new unit tests, including a real interactive-prompt test for `expect`
(`TestExpect_RealScriptRespondsToPrompt`, a genuine shell script with a real `read`) and the
`git` regression test (`TestGit_RealCloneAndUpdate`) that caught the branch-advancement bug above.
`reboot` deliberately has **no** real invocation anywhere, including in this batch's manual
verification below — the module's own doc comment explains why (the calling process would be
killed by the very action it triggers), and actually rebooting the shared test host would disrupt
whatever else runs there; coverage is fake-`Runner`-only; this mirrors the precedent already set
by Batch 4's RedHat-family modules (unit-tested only, no real toolchain available to test against)
and Batch 5's `iptables` (real command's exact argv verified without ever touching a live traffic
chain).

Eleven of the twelve modules also ran for real against `host1.example.internal`: `ping`,
`systemd_service` (status query against the real `ssh.service`), and `script` (a real `/bin/echo`
call) round-tripped over genuine REST calls. `git` cloned a real local repository, confirmed
idempotent on a repeat call, then confirmed a second real upstream commit was correctly fetched
and checked out — the exact scenario the branch-advancement fix targets. `unarchive` extracted a
real zip (built via Python's `zipfile` module, since neither `zip` nor a suitable substitute was
preinstalled) and confirmed the `creates` idempotency skip. `package` correctly detected the
Debian `apt-get` backend and reported the already-installed `bash` package as `changed: false`.
`sysvinit` — expected to be untestable on a systemd-only host — turned out to work fully for real:
this Debian 13 install still ships LSB-compatible `/etc/init.d` scripts (e.g. `cron`), so both the
running-state (`status`) and enabled-state (`S##` symlink glob) checks were confirmed against a
genuine service. `expect` answered a real interactive `read` prompt in a throwaway shell script.
`debconf` needed the daemon restarted as root (writing debconf's database requires root even
though the read side doesn't) — once running as root, it set a real value, confirmed via
`debconf-show`, and confirmed idempotent on a repeat call. `pip` and `subversion` needed two
packages the test host didn't have yet (`python3-venv`, `subversion` — both installed via
`apt-get install`, left in place afterward as harmless additions, not reverted): `pip` created a
real virtualenv and confirmed its own pip's version via `pip show`; `subversion` checked out a
real local `file://` repository, confirmed idempotent, then confirmed a second commit was
correctly fetched and updated — the same update-detection shape as the `git` test. Only `reboot`
was not exercised against the live daemon, for the reason stated above. This completes the
`ansible.builtin` module coverage plan: all ~28 modules in the confirmed real-remaining scope are
now implemented.

**Addendum — two modules missed by the original scoping pass:** a user recount of
`ansible-doc -l | grep ansible.builtin | wc -l` (71) against this project's own confirmed
19-module exclusion list turned up a real gap the original Batch 6 scoping missed: `raw` and
`shell` were never explicitly added to either the "excluded" or "in scope" list, and so were
simply never built. Both are now closed out:

- **`raw`** — a trivial alias of `command`. Real Ansible's `raw` exists to run a command over SSH
  on a target with no Python installed yet, bypassing the module subsystem entirely as a
  bootstrapping mechanism; this agent is a single compiled Go binary with no such bootstrap
  problem, so `raw` and `command` behave identically here, the same reasoning that already makes
  `fetch` an alias of `slurp` and `script` an alias of `command`. Unit-tested only (there's
  nothing `command`'s own tests don't already cover); no separate real-host verification needed
  for the same reason.
- **`shell`** — required an explicit decision rather than a unilateral one, since a faithful
  implementation directly conflicts with this project's stated security model ("no shell
  interpreter" — see Security model above). Real `ansible.builtin.shell` runs a command through
  `/bin/sh -c`, meaning pipes, redirects, globbing, and `$()` substitution all work — none of
  which an argv array can express. Presented three options to the project owner (real `sh -c`
  accepting the injection-risk trade-off; a fake "shell" that's actually routed through the
  existing whitelisted pipeline system with no real shell involved; or leaving it deliberately
  unimplemented) — **the real `/bin/sh -c` option was chosen**. `internal/modules/shell.go`
  implements it accordingly, with the trade-off stated prominently in the module's own
  `Description()` (so any AI client reading tool docs before calling it sees the warning) and
  cross-referenced from the Security model section above. Verified with a real end-to-end test
  proving genuine shell interpretation — a real pipe (`echo hello | tr a-z A-Z` → `HELLO`) and a
  real redirect + glob (`echo redirected > out.txt && cat out*.txt`) — since that's the entire
  point of the module and something no fake-Exec unit test could actually prove. Both `raw` and
  `shell` also ran for real against `host1.example.internal` via genuine REST calls against
  the compiled binary: `raw` executed a plain `/bin/echo`; `shell` reproduced the same pipe and
  redirect+glob behavior confirmed locally, over the network against the real daemon.

## Roadmap (after this v1 — separate plans)

- **Multi-task plan/apply (playbook-style) with confirmation** — the full Ansible replacement,
  building on the now-complete `ansible.builtin` module coverage above.
- **Fleet Commander (Python/FastAPI, the last step, codename "Bossman"):** agent registry,
  fleet-wide aggregation in MariaDB/PostgreSQL, cross-host service map, an MCP facade for the AI,
  alerting (the CheckMK replacement), discovery via NetBox. Also owns translating foreign
  orchestrator formats into this agent's module calls: a tiered strategy — a real parser for
  Ansible playbooks and SaltStack states (both plain YAML, structurally close to this project's
  own `tools.d` format: a list of `module: {params}` steps — parsing them directly avoids ever
  having the AI read the raw playbook text, the most token-efficient option), and a lightweight
  mapping reference (not a parser) for Puppet manifests and Chef recipes, since both are full
  DSLs/imperative languages (Chef is Ruby) that an AI can already read fluently on its own — it
  only needs the vocabulary mapping to this project's module names, not a translation engine.
  Terraform is lower priority: it mostly manages cloud infrastructure rather than host state, so
  only its `local-exec`/`remote-exec` provisioner blocks are a natural fit. This strategy is
  deliberately *not* implemented in this repo — the Node Agent stays narrowly scoped to exposing
  metrics and executing well-defined module calls; foreign-format translation is Fleet Commander
  work.
- **v3 (implemented — see "v3" section below):** mTLS (verified already generic), per-token RBAC
  (token → allowed tool set), `.rpm`, eBPF expansion (disk I/O latency, container awareness)

## v3 — mTLS verification, per-token RBAC, `.rpm` packaging, eBPF expansion (implemented)

Prompted by the user's explicit direction to work through the v3 roadmap items before starting on
Bossman. All four items below are implemented, tested, and real-verified.

### mTLS — verified already generic (no code change needed, but previously untested)

`cmd/agentic-mcpd/http.go`'s `requireTrustedClientCert`/`withBearerAuth` already gated **any**
direct caller to `/mcp` and `/api/v1/*` whenever `tls.trusted_client_keys` is configured — not
just the proxy/satellite-puller path. This was true before this session but had **zero dedicated
test coverage** (`internal/fleet/puller_test.go` only exercises the *client* side against a
hand-mimicked test server, not the real production gate function). Added
`cmd/agentic-mcpd/http_test.go`: real TLS handshakes via `httptest`-style servers proving a direct
caller (not a proxy) is correctly gated by both the bearer token and the client-cert pin, that
they compose as defense-in-depth (right cert + wrong token fails, right token + wrong cert fails),
and that `loadTrustedClientKeys` skips broken entries gracefully. No production code changed;
existing behavior confirmed correct and now has regression coverage it lacked.

### Per-token RBAC — `internal/authz.TokenEntry`/`ResolveBearerToken`, `config.NamedToken`

Previously every bearer-token caller — MCP or REST — resolved to the same fixed
`authz.TokenIdentity` ("service-token"), so an ACL rule scoped to a token principal could never
actually differentiate between callers. Implemented:

- `internal/authz/token.go`: `TokenEntry{Name, Token}` + `ResolveBearerToken(presented, legacyToken,
  extra []TokenEntry) (Identity, bool)` — constant-time comparison against the legacy token (→
  fixed `TokenIdentity`, unchanged for backward compatibility) and each named entry (→
  `Identity{Kind: KindToken, Name: entry.Name}`).
- `internal/authz/context.go`: `WithIdentity`/`IdentityFromContext` — since MCP tool-call handlers
  only ever receive a `context.Context`, not the originating `*http.Request`, the resolved
  identity has to travel via the request context the bearer-auth middleware already touches.
- `internal/config`: new `Config.Tokens []NamedToken` (validated: unique non-empty names, no
  collision with the reserved `service-token` name, non-empty token values) +
  `Config.TokenEntries()` conversion helper.
- `cmd/agentic-mcpd/http.go`'s `withBearerAuth` now resolves and attaches the caller's `Identity`
  to the request context on a match (MCP path); `internal/server/rest.go`'s `identityFromRequest`
  does the same for REST via a new `RESTConfig.Tokens` field.
- `internal/server/modules.go`/`tasks.go`/`upload.go`: `checkACL`/`registerModuleTool` etc. now
  resolve the caller's identity from context (`mcpCallerIdentity`, falling back to the fixed
  `TokenIdentity` when nothing was attached — e.g. auth disabled entirely) instead of hardcoding
  it, so a named token's ACL rules actually apply to its own MCP calls.

**Verified:** unit tests for the resolver/context helpers and config validation; a decisive
`cmd/agentic-mcpd/rbac_test.go` end-to-end test using a **real** `mcp.Client` over a **real**
`mcp.NewStreamableHTTPHandler` HTTP connection (not an in-memory transport) — two different tokens
presented over the wire resolve to two different identities and get genuinely different ACL-scoped
tool access; confirmed this test would have failed against the old code (temporarily reverted
`mcpCallerIdentity` to always return the fixed identity — the test failed exactly as expected,
then restored). Also verified live against `host1.example.internal`: a daemon configured
with a legacy token and two named tokens (`bossman`, `readonly-ci`), an ACL rule granting only
`bossman` access to `ping`, confirmed via real REST calls — `bossman` token can call `ping` (200)
but not `setup` (403); the legacy token and the other named token are both denied `ping` (403),
proving the ACL rule genuinely differentiates between tokens rather than granting blanket access
to anyone with *a* valid token.

### `.rpm` packaging — `packaging/nfpm.yaml`, `postinst`, `postrm`

One shared `nfpm.yaml` (nfpm builds both `.deb` and `.rpm` from the same config) plus `postinst`
(first-install-only: bootstraps `config.yaml` from the shipped example, generates a random token
via `agentic-mcpd --generate-token`, `chmod 0600`, `systemctl enable`+`restart`) and `postrm`
(stops/disables the service; deliberately never deletes `/etc/agentic-mcp` or
`/var/lib/agentic-mcp` — losing the bearer token or accumulated metrics/audit history on a routine
package removal would be a destructive surprise). `.deb` install-testing remains explicitly
deferred per the user's direction (Schritt 12 of the original v1 plan); only `.rpm` was built and
verified this round, since that's what v3 actually asked for.

**Verified, real, end to end:** built via `nfpm package -f nfpm.yaml -p rpm`; installed with real
`rpm -ivh` in a plain `rockylinux:9` container (files/permissions/token-generation correct;
reinstall after `rpm -e` correctly leaves `config.yaml` in place and does **not** regenerate the
token); installed and run in a **real systemd-enabled** `rockylinux/rockylinux:9-ubi-init`
container (`--privileged --cgroupns=host`) — `systemctl status` showed the service genuinely
`active (running)`, `enabled`, eBPF collector attached, and a real `curl` REST call
(`POST /api/v1/tools/ping`) against the systemd-managed daemon succeeded.

### eBPF expansion — disk I/O latency + container-awareness

**Disk I/O latency** (`internal/ebpf/bpf/collector.c`, `tracepoints.h`): two new stable tracepoints,
`block:block_rq_issue` and `block:block_rq_complete`, correlated in-kernel by `(dev, sector)` (the
standard blktrace correlation key, same approach BCC's `biolatency` uses) via a
`BPF_MAP_TYPE_HASH` — a request seen mid-flight when the collector attaches (issue missed) is
silently skipped rather than reported with a guessed latency. New `DiskIOEvent` Go type
(comm/pid/dev/sector/nr_sector/latency/rwbs/error), `RecentDiskIO`/`SlowestDiskIO` accessors, new
MCP tools `disk_io`/`slow_disk_io` and REST routes `GET /api/v1/disk-io`/`/api/v1/disk-io/slowest`.

Hit a real verifier rejection during development: reading `ctx->ent.pid` (the tracepoint's *common*
header, shared across all tracepoint types) is rejected by the BPF verifier for
`tracepoint/*` programs ("invalid bpf_context access") — only the tracepoint-*specific* fields
after the common header are checked/allowed. Fixed by using `bpf_get_current_pid_tgid() >> 32`
instead (the same technique `trace_inet_sock_set_state` already used), which is verifier-safe
regardless of tracepoint argument layout. Caught immediately by real-host verification (unit tests
alone, which don't load real BPF bytecode, could not have caught this).

**Container-awareness** (`internal/ebpf/container.go`): deliberately **not** implemented as
further eBPF/kernel work — walking kernel cgroup structs directly would need CO-RE/BTF relocation
(exactly the complexity this collector's tracepoint-only design otherwise avoids), whereas every
event already carries a pid, and `/proc/<pid>/cgroup` is a stable userspace interface for the same
lookup. `containerIDForPID`/`containerIDFromCgroupData`: reads `/proc/<pid>/cgroup`, extracts the
longest hex run (12–64 chars) across all lines — matching Docker's own cgroup driver
(`/docker/<64-hex>`), Docker via the systemd cgroup driver (`docker-<64-hex>.scope`), and
containerd/CRI (`cri-containerd-<64-hex>.scope`, used for both standalone containerd and
Kubernetes) uniformly, without special-casing each runtime. Best-effort: empty string (omitted
from JSON via `omitempty`) if the process already exited, isn't containerized, or the path doesn't
match — never an error, since this is enrichment, not core event data. Added to `TCPConnEvent`,
`ExecEvent`, and the new `DiskIOEvent` (which needed a `pid` field added to its eBPF-side
correlation map value, populated at issue time, since `block_rq_complete` itself carries no pid).

**Verified:** unit tests against realistic real-world cgroup path formats for all three runtime
patterns plus bare-metal (no false positives), an injectable-reader test, and a real
`/proc/<pid>/cgroup` read against the test binary's own PID. Real, end-to-end verification on
`host1.example.internal`: real disk I/O generated (`dd`/`sync`/`cat` of a 100 MiB file) and
retrieved via the real REST endpoints — genuine device numbers, sectors, and latencies (a 17.6ms
journal write, ~30–45µs small kworker writes, real process names like `sssd_be` and
`kworker/1:1H`). Container-awareness verified without needing a real container runtime (the test
host has no outbound internet access to pull an image): manually placed a real process into a
Docker-style cgroup path (`/sys/fs/cgroup/docker-test-fake/docker-<64-hex>.scope/cgroup.procs`,
real cgroupfs, no simulation) and confirmed real `exec_events` captured from within it carried the
exact matching `container_id` — proving the full pipeline (kernel event → pid capture → `/proc`
lookup → JSON output) end to end.

## Bossman — Block A: durable connection-edge persistence (implemented)

The first piece of the Bossman plan (see the "Ergänzung: Bossman (Fleet Commander)" plan history):
Bossman's design assumes it can pull connection-relationship data with real history from every
node agent, the same way it already pulls metrics via `GET /api/v1/metrics`. Before this block,
`ebpf.Collector`'s TCP connection data lived only in a RAM-only, capped ring buffer — no
persistence, no cursor, no bulk-dump path, and a lossy window under any polling gap or restart.

- **`internal/store`**: new `connection_edges` table (`comm`, `dst_addr`, `dst_port`,
  `event_count`, `first_seen`, `last_seen`, `latency_ns`, unique on `(comm, dst_addr, dst_port)`)
  plus `Store.UpsertEdge`/`ListEdgesSince` — the exact shape from the earlier Bossman planning
  session, deliberately its own table rather than shoehorned into the generic
  `Point{metric,value,labels}` schema (an edge has several non-numeric dimensions that don't fit).
  `Downsample` now also prunes edges last seen before the raw cutoff (`DownsampleStats.EdgesPruned`),
  riding the exact same retention cadence as metrics rather than a second cron mechanism.
- **`internal/ebpf`**: new `EdgeSink` interface (`UpsertEdge(ctx, comm, dstAddr, dstPort, latencyNs)
  error`) — deliberately *not* an import of `internal/store` from `internal/ebpf`, since
  `store.Store` already has this exact method set and therefore satisfies `EdgeSink` structurally,
  no adapter needed. `Collector.SetEdgeSink` wires it optionally (nil is a fully valid, working
  collector — same graceful-degradation posture as every other dependency here); on each
  `ESTABLISHED` transition (the same aggregation `TopTalkers` already computes in memory), the
  collector also calls the sink, best-effort (a logged warning, never a fatal error, on failure).
- **`internal/server`**: new `GET /api/v1/net/connections/dump?since=<RFC3339 or duration>` —
  the durable, cursor-based counterpart to the existing live `net_connections` tool/route.
  Deliberately **REST-only, no MCP tool** — this endpoint is for machine-to-machine fleet polling
  (a proxy, or Bossman), not for an AI to call directly (which already has `net_connections`/
  `top_talkers` for the live view) — directly matching the user's explicit direction that Bossman
  should poll node agents over REST, not MCP.
- **`cmd/agentic-mcpd/main.go`**: `collector.SetEdgeSink(st)` wired right after the collector
  starts, since `st` (the already-open `store.Store`) satisfies `ebpf.EdgeSink` with zero glue code.

**Verified:** unit tests for the store methods (idempotent upsert-by-identity, event count
increments, `first_seen` stays fixed across repeats, latency preserved when a later observation
carries none, cursor filtering, pruning), a fake-`EdgeSink` test proving only `ESTABLISHED`
transitions trigger a persist call, and REST route tests. Real, end-to-end, on
`host1.example.internal`: generated genuine loopback TCP connections, confirmed the dump
endpoint returned them with correctly aggregated `event_count` (4 for 4 repeated connections to
the same port) — then **killed and restarted the daemon** and confirmed the previously observed
edges were still present in the dump afterward, the exact guarantee (restart-survival) that
motivated moving off the RAM-only ring buffer in the first place.

## Bossman — Block B1/B2: FastAPI scaffold + TimescaleDB schema (implemented)

`bossman/` (a new subdirectory of this same repo, per the confirmed monorepo-not-separate-repo
decision): a `uv`-managed Python project, app-factory pattern (`create_app`, not a module-level
singleton, so tests don't need the real lifespan/DB pool to run), `pydantic-settings` config read
from `BOSSMAN_`-prefixed env vars (not a YAML file like the Go agent — Bossman follows this team's
conventional env-var-configured service pattern instead), `/healthz` matching the Go daemon's own
bare, unauthenticated liveness-check convention.

**Schema** (SQLAlchemy 2.0 declarative models in `bossman/db/models.py`, Alembic migration in
`bossman/alembic/versions/`): `agents`, `host_edges` (aggregated relationships), `connection_events`
+ `metrics` (TimescaleDB hypertables — raw history), `metrics_hourly` (continuous aggregate, the
RRD-replacement rollup), `plan_runs`/`plan_run_steps` (the Ansible-replacement audit trail),
`bossman_users`/`api_tokens` (the dual human/machine auth split already decided). Hypertable/
continuous-aggregate/retention-policy calls are raw SQL in the migration (`op.execute(...)`) since
none of that is expressible via SQLAlchemy's own DDL — the ORM models only describe each table's
plain relational shape.

**Two real bugs found and fixed while actually running this against a real database** (not just
reviewing the code):
1. `CREATE MATERIALIZED VIEW ... WITH (timescaledb.continuous)` cannot run inside a transaction
   block by default (it tries to materialize immediately, which TimescaleDB implements outside
   transactional DDL) — Alembic wraps every migration in a transaction. Fixed with `WITH NO DATA`
   on the `CREATE MATERIALIZED VIEW`, which skips the immediate materialization; the continuous
   aggregate policy refreshes it on its own schedule regardless, so nothing is lost.
2. Every timestamp column defaulted to Postgres `TIMESTAMP WITHOUT TIME ZONE` (SQLAlchemy's plain
   `DateTime()`), which `asyncpg` then refuses to bind a timezone-aware Python `datetime` into — a
   real, immediate failure the moment a real integration test tried to insert one. Since a fleet
   spans hosts across timezones, comparing/bucketing naive timestamps would have been silently
   wrong even if the driver had allowed it. Fixed by making every timestamp column explicitly
   `DateTime(timezone=True)`.

**Verified, real, not mocked:** a real `timescale/timescaledb:latest-pg16` Docker container as the
dev database (see `bossman/README.md`); `alembic upgrade head` / `alembic downgrade base` both run
successfully against it; confirmed via `psql` that `connection_events`/`metrics` are genuine
hypertables (`timescaledb_information.hypertables`), `metrics_hourly` is a genuine continuous
aggregate, and all three retention/refresh policies are actually registered as scheduled background
jobs (`timescaledb_information.jobs`) — not just that the migration ran without erroring. A real
pytest integration suite (`tests/test_models.py`, skips gracefully if no database is reachable
rather than mocking one away) inserts and queries rows through the actual ORM models against the
real hypertables, including the two bugs above being caught by this exact test suite before ever
being committed.

## Bossman — Block B3: enrollment server (implemented)

Bossman's server side of the exact same handshake the Selecta section above already implements —
`POST /api/v1/enroll` accepting `{name, enroll_secret, token, address}` and returning
`{bossman_public_key, agent_id}`. No new wire protocol: this is the contract `internal/enroll`
(the Go `agentic-mcpd register` client) was written against from the start.

**`bossman/bossman/services/keys.py`** (new): `ensure_client_keypair(key_path, cert_path)`
generates a P-256 keypair + self-signed certificate once and persists it to disk — idempotent, a
restart reuses the existing identity rather than silently rotating it (rotation would require
re-running enrollment against every already-enrolled agent, an accepted v1 trade-off per the plan
above). `own_public_key_pem(cert_path)` extracts the PEM-encoded PKIX public key from that
certificate — the direct Python counterpart of the Go node agent's
`tlsauth.PublicKeyPEMFromCertFile`, handed out during enrollment so a Duppy can pin it in its own
`tls.trusted_client_keys` exactly like a Selecta's client certificate.

**`bossman/bossman/services/enrollment.py`** (new): `enroll_agent(session, configured_secret,
EnrollRequest)` — framework-free business logic (no FastAPI import), so it stays reachable from
the REST API, a future MCP facade, and tests without duplicating logic. Validates the caller's
`enroll_secret` with `secrets.compare_digest` (constant-time, mirroring the Go daemon's own
`crypto/subtle.ConstantTimeCompare`) and upserts an `Agent` row by name — a first-time enrollment
creates it `enrolled`; re-enrolling an already-known name (reinstall, token rotation) updates the
existing row in place instead of erroring, mirroring the Go Selecta's `Manager.Enroll`
re-enrollment semantics.

**`bossman/bossman/api/enroll.py`** (new): the FastAPI route, mounted in `create_app()` only when
`settings.enroll_secret` is non-empty — an unconfigured Bossman accepts no enrollments at all,
identical gating to the Go Selecta's `proxy.enroll_secret`. `400` on an empty `name`/`token`,
`401` on a wrong `enroll_secret` (propagating `InvalidEnrollSecret`), `200` with the freshly
generated/loaded public key and the agent's UUID on success.

**Real bug found and fixed while wiring this up, not by code review:** a DB-backed HTTP test using
two separately-constructed `TestClient` instances failed with `RuntimeError: ... got Future ...
attached to a different loop` — `bossman/db/session.py`'s original `_engine` was a module-level
singleton created once at import time, but each `TestClient` spins up its own event loop, and a
pooled `asyncpg` connection created under one loop cannot be reused under another (this is exactly
the DB-pool wiring Block B1's scaffold had explicitly deferred to "a later block" in
`bossman/main.py`'s lifespan, just never exercised until a DB-backed HTTP test existed). Fixed by
binding the engine's lifetime to the FastAPI app instance instead of the process: `make_engine()`
is now called inside `lifespan()`, storing the session factory on `app.state`, and
`get_session(request: Request)` reads it from there — disposed cleanly in `lifespan`'s `finally`
block on shutdown. This is also the architecturally correct shape per the original B1 plan, not
just a test workaround.

**Verification:**
- `tests/test_keys.py` (3 tests): keypair generation, idempotency (identical bytes across two
  calls), and that the extracted public key is well-formed PEM.
- `tests/test_enrollment_service.py` (3 tests, real DB via `db_session`): new-agent creation,
  re-enrollment updating the existing row in place (not creating a duplicate), and wrong-secret
  rejection creating no row.
- `tests/test_enroll_api.py` (4 tests, real DB, real HTTP via `TestClient(app)` as a context
  manager so the lifespan actually runs): success end to end, the same keypair being returned
  across two different enrollments (proving persistence, not per-call regeneration), wrong-secret
  rejection, and route absence (404) when no `enroll_secret` is configured.
- **Real end-to-end run, the actual Go binary against the actual Bossman dev server** (not just
  Python-side tests): `uv run uvicorn bossman.main:app` was started for real against the same
  `timescale/timescaledb` dev container Block B1/B2 verified against, with a real
  `BOSSMAN_ENROLL_SECRET` set. The real, freshly-built `agentic-mcpd` binary's `register`
  subcommand was run against it (`--enroll-url http://127.0.0.1:8090 --enroll-secret e2e-secret
  --name duppy-e2e-1 --address 127.0.0.1:8091`) and succeeded, printing a real agent UUID and
  writing a real PEM public key to disk (confirmed valid with `openssl pkey -pubin -text`, a real
  P-256 key, not just PEM-shaped text). `psql` confirmed the real row in `agents`
  (`enrollment_state='enrolled'`, correct `token`/`address`). A second `register` call with a
  wrong `--enroll-secret` failed for real with the server's actual 401 propagated into the CLI's
  error message (`register: enrollment rejected: 401 Unauthorized: {"detail":"invalid
  enroll_secret"}`). Test rows and the dev Bossman process were cleaned up afterward.

## Bossman — Block B4: agent client + poller (implemented)

For each enrolled agent, pulls `GET /api/v1/metrics` and `GET /api/v1/net/connections/dump` on an
interval and writes the results into `metrics`/`host_edges` — the RRD-replacement and
relationship-graph ingestion path described in the plan above (section B.4).

**`bossman/bossman/services/agent_client.py`** (new): `AgentClient` mirrors the Go proxy's own
`internal/fleet.Puller` byte for byte in protocol terms — `Authorization: Bearer <token>` header,
Bossman's own client certificate presented for mTLS, `verify=False` (Bossman does not verify the
agent's server identity; trust runs the other way, matching the already-documented proxy-mode
trade-off). `metrics_dump(from_)`/`connections_dump(since)` omit the query parameter entirely when
given `None` rather than inventing a lookback window — the agent's own REST defaults (1h for
metrics, 24h for connections) apply on a first pull, and an explicit cursor is passed on every
pull after that.

**`bossman/bossman/services/poller.py`** (new): `poll_once(session_factory, settings,
client_factory=...)` loads every `enrollment_state='enrolled'` agent and polls each concurrently,
bounded by `asyncio.Semaphore(settings.poll_concurrency)` (default 10) — no task queue
(Celery/Redis), matching the plan's stated reasoning at this fleet's targeted scale (~100 hosts).
`client_factory` exists solely so tests can substitute a fake `AgentClient` instead of a real one
— the same test seam the Go proxy's `Manager.pullerFactory` already established
(`internal/fleet/manager.go`) for an identical reason. `poll_agent` pulls metrics and connection
edges independently (either can fail without blocking the other) and only advances each resource's
own cursor (`Agent.last_metrics_pulled_at`/`last_edges_pulled_at`, added in this block's migration)
on that resource's success — `Agent.last_seen_at` updates if *either* pull reached the agent at
all. Metric inserts use `ON CONFLICT DO NOTHING` (idempotent against cursor-boundary overlap
without erroring on the hypertable's `(time, agent_id, metric)` primary key); `HostEdge` upserts by
its natural key (`src_agent_id, src_comm, dst_addr, dst_port`), overwriting `event_count` (already
a lifetime cumulative counter from the agent, not a per-window delta) and best-effort resolving
`dst_agent_id` by matching a known agent's `address` host part against the edge's `dst_addr`.
`poller_loop` runs `poll_once` on `settings.poll_interval_seconds` until an `asyncio.Event` is set.

**`bossman/bossman/main.py`**: the poller is started as a background `asyncio.create_task` in the
app's `lifespan`, and — critically — **cancelled**, not just signaled-and-awaited, on shutdown: a
poll cycle can be blocked on a slow/unreachable agent's HTTP call (up to its own 30s timeout), and
`task.cancel()` interrupts that immediately via `asyncio.CancelledError` rather than stalling every
test that exercises the lifespan (and a real shutdown) for up to 30 seconds.

**Schema change:** `alembic/versions/8ddf50da59f5_agent_poll_cursors.py` adds
`agents.last_metrics_pulled_at`/`last_edges_pulled_at`. Autogenerate also proposed *dropping*
`connection_events_time_idx` and `metrics_time_idx` — deliberately not applied. Both are
TimescaleDB's own indexes, created automatically by `create_hypertable()` in the initial migration
and invisible to SQLAlchemy's model introspection, which is exactly why autogenerate misread them
as removed; applying that diff would have silently degraded every time-range query against both
hypertables. Caught by reading the generated migration before running it, not by a failing test —
a reminder that autogenerate output is a draft, not a commit-ready artifact.

**Real bug found in bootstrapping this block's own tests, not in the poller logic itself:**
`HostEdge.dst_addr` is a Postgres `INET` column, so SQLAlchemy returns an `ipaddress.IPv4Address`
object on read, not a `str` — a first version of `tests/test_poller.py` asserted
`edge.dst_addr == "9.9.9.9"` and failed immediately with a real, informative `AssertionError`,
fixed by comparing `str(edge.dst_addr)` instead. A second, separate issue in the same test file:
deleting a `HostEdge` and its parent `Agent` in the same session without an intermediate
`session.flush()` let SQLAlchemy attempt the `DELETE FROM agents` before the child `DELETE FROM
host_edges` had actually executed, raising a real `ForeignKeyViolationError` — fixed by flushing
after deleting child rows and before deleting the parent in every test's cleanup.

**Verification:**
- `tests/test_agent_client.py` (6 tests, `httpx.MockTransport` — no real network, no real cert
  files needed since httpx doesn't validate `cert=` paths when a custom transport is supplied):
  correct URL/headers/query params, RFC3339 UTC formatting of the `from` cursor, and every error
  path (non-200 status, network failure, invalid JSON).
- `tests/test_poller.py` (6 tests, real DB via `db_session`, `FakeAgentClient` injected via
  `client_factory`): metrics + edges both written and cursors both advance on success; a failing
  metrics pull leaves `last_metrics_pulled_at` unset while a succeeding edges pull still advances
  `last_edges_pulled_at` and `last_seen_at` (independent-failure proof); an agent with no address
  is skipped without any network attempt; the first poll passes no cursor while the second passes
  the first's timestamp; re-polling the same edge updates the existing row in place (not a
  duplicate) with the new `event_count`; `poll_once` only ever selects `enrolled` agents, skipping
  `pending` ones.
- **Real end-to-end run against an actual `agentic-mcpd` binary** (not the Python-side fake):
  reused this block's own B3 enrollment flow for real (`agentic-mcpd register` against a live
  Bossman dev server) to enroll a real, TLS-enabled Duppy, added the handed-out Bossman public key
  to the Duppy's own `trusted_client_keys`, and restarted it — confirmed `client certificate
  required` when polled without one first, proving mTLS was actually enforced, not just configured.
  Called `poll_once` directly against the real dev database with the **real** (non-fake)
  `client_factory`, presenting Bossman's real client certificate: the real `agentic_mcpd_start`
  startup-marker metric (the same marker the v3 proxy/satellite work already relied on for its own
  real-traffic verification) was pulled and written — `psql` confirmed two real rows (one per
  Duppy process start observed) with correct `agent_id`/`metric`/`value`/`time`. A second
  `poll_once` call against the same, now-current cursor wrote zero additional rows — the dedup
  path was exercised for real, not just asserted against a mock. `edges_written` was `0` in this
  run since no eBPF connections existed on the disposable local test agent — the edges write path
  itself is covered by the real-DB `FakeAgentClient` tests above and by the Selecta section's own
  earlier real-eBPF verification on `host1.example.internal`, so this run's scope was
  deliberately the metrics/cursor path. All test rows, processes, and scratch files were removed
  afterward.

## Bossman — Block B5: plan loader + plan engine (implemented)

The filesystem-native plan format from the plan above (section B.5): "take plan X, run it against
host Y" instead of the AI orchestrating individual module calls itself.

**`bossman/bossman/services/plan_loader.py`** (new): deliberately byte-for-byte syntax-compatible
with the Go node agent's own `tools.d/*.yaml` single-task format (`internal/tasks/task.go`) — same
`ansible.builtin.<module>:` key, `params: {type, required, pattern, default}`, and `{{ placeholder
}}` substitution rules (a string that is *entirely* one placeholder keeps the argument's native
type; embedded placeholders stringify; an unresolved reference is a hard error, never a silent
no-op) — ported statement-for-statement so an operator who already knows tools.d syntax needs
nothing new to write a plan step. What a plan adds on top of a single task: an ordered `steps:`
list where each step is a module call, a `pipeline:`, or a new `upload:` step type (`local_path` +
`remote_name`, driving the file-upload staging path documented earlier in this file), plus
per-step `check_mode`/`on_failure` ("abort" default, or "continue"). `load_plans_dir()` mirrors the
Go tools.d loader's behavior exactly: sorted, duplicate-name detection, a missing directory yields
no plans rather than erroring. `load_host_vars()` reads
`<plans_dir>/host_vars/<hostname>.yaml`. `resolve_params()` merges `params.default < host_vars <
explicit-call-params` (in that precedence) and validates required/type/pattern, mirroring the Go
parser's `buildArgs`. `Plan.version()` is a sha256 of the plan file's own bytes — a drift-detection
value for `plan_runs.plan_version` ("was the file edited since this run happened"), not a
hand-maintained version number.

**`bossman/bossman/services/agent_client.py`** extended with `call_tool(name, body)` (`POST
/api/v1/tools/{name}`) and `upload_file(remote_name, data)` (`PUT /api/v1/upload?name=`, the raw-
body path documented in this file's "File upload (staging)" section) — both raising
`AgentClientError` on any non-200/network failure, same contract as the existing
`metrics_dump`/`connections_dump` methods.

**`bossman/bossman/services/plan_engine.py`** (new): `run_plan(session, agent, plan, host_vars,
explicit_params, dry_run, client, requested_by)` resolves parameters, creates the `PlanRun` row,
then executes every step in order, recording each into `plan_run_steps` regardless of outcome —
`PlanError`/`AgentClientError`/`OSError` are all caught per-step and stored as that step's `error`,
never allowed to abort the whole run and leave nothing persisted. Only a parameter-resolution
failure *before* the `PlanRun` row is created propagates as a raised `PlanError` — once the row
exists, a persisted partial audit trail is the point of a plan run, not an exception.

Per-step `check_mode` (or the run's own top-level `dry_run`) only actually changes behavior for a
**module** step, where it's injected as `"dry_run": true` in the request body sent to
`/api/v1/tools/{module}` — this is genuinely how the Go node agent's own modules implement
check_mode (a `dry_run` boolean *parameter inside the module's own params*, confirmed by reading
`internal/modules/apt.go` et al.; the REST/MCP server layers always call `Module.Run(..., false)`
for the wrapper argument, so this is the *only* way to trigger it over the wire). `pipeline` and
`upload` steps have no such capability on the agent side — a dry-run pipeline or upload step is
therefore **skipped entirely** (no HTTP call at all) with a synthetic `{"skipped": "..."}` response
body recorded, rather than either running for real during a preview or pretending to predict an
effect neither step type can actually preview.

`PlanRun.status` becomes `"failed"` if *any* step errored (regardless of whether `on_failure` let
the run continue past it) or `"succeeded"` otherwise — `"aborted"` (also a valid value per the
schema's `CheckConstraint`) is reserved for a future explicit-cancellation feature, not produced by
this block.

**Verification:**
- `tests/test_plan_loader.py` (25 tests, no DB, no network): every step kind parses correctly
  (module/pipeline/upload), every malformed-plan error case (missing name/steps, multiple module
  keys, unknown step key, bad `on_failure`), `load_plans_dir`/`load_host_vars` behavior including
  duplicate-name and missing-directory cases, `resolve_params`'s full precedence chain and every
  validation failure (missing required, pattern mismatch, wrong type, unknown param),
  `substitute`'s type-preservation vs. stringification rules and nested dict/list walking, and
  `Plan.version()` actually changing when the file's content changes.
- `tests/test_plan_engine.py` (11 tests, real DB via `db_session`, `FakeAgentClient` — the same
  test-seam pattern as the poller and the Go proxy's own `Manager.pullerFactory`): a full
  successful run recording the right step/status/params/version; a failing step recorded with its
  error and the run marked `failed`; `on_failure: continue` running the remaining steps vs. the
  default `abort` stopping immediately; a module step's dry-run correctly injecting `dry_run: true`
  into the body; a step-level `check_mode: true` forcing dry-run behavior even when the overall run
  isn't a dry run; pipeline and upload steps both actually invoked when not a dry run and both
  genuinely skipped (zero calls to the fake client) when they are; a missing required parameter
  raising before any `PlanRun` row is created (no orphan row left behind).
- **Real end-to-end run against an actual, write-enabled `agentic-mcpd` binary** (not the Python
  fake): a three-step plan (a `copy` module step, a `pipeline` step chaining `echo`/`wc` through
  the agent's real command-whitelist policy, and an `upload` step) was run for real via `run_plan`
  with a genuine (non-fake) `AgentClient` against a real, running Duppy. All three steps came back
  `changed: true`/`http_status: 200` with no errors, `PlanRun.status == "succeeded"`, and — checked
  independently of the recorded results — the actual side effects were real: `motd.txt` on disk
  contained the exact substituted parameter value (`"hello from e2e"`), and the uploaded file
  landed byte-for-byte in the agent's real staging directory. Test rows, processes, and scratch
  files were removed afterward.
