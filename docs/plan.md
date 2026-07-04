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
IPv4 only in v1 (IPv6 stays on the v3 roadmap alongside deeper eBPF expansion). Graceful
degradation is real: `startEBPFCollector` in `main.go` logs a warning and returns `nil` on any
failure (missing CAP_BPF, old kernel, ...), and every registration point (`RegisterEBPF`,
`RegisterEBPFRoutes`) is a no-op for a nil collector — verified locally in this sandbox (no
root) where the daemon started fine with the log warning and the eBPF tools were simply absent.

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

## Bossman enrollment (`agentic-mcpd register`, implemented)

The three operating modes above rely on `tls.trusted_client_keys` being populated with a caller's
pinned public key — previously only achievable by manually copying a key file to every agent.
Once a central Fleet Commander ("Bossman," see the Roadmap) exists, doing that by hand across a
whole fleet doesn't scale. `agentic-mcpd register` is this agent's client-side half of a one-time
bootstrap handshake that automates it — even though Bossman itself doesn't exist yet, this
repo defines the contract a future Bossman implementation must satisfy, and ships/tests the
client side against it now.

**Protocol:** `POST <bossman-url>/api/v1/enroll` with a JSON body `{name, enroll_secret, token,
address}` — `name` identifies this agent (defaults to its hostname), `enroll_secret` is a shared
bootstrap secret proving this agent is authorized to join the fleet (the only authentication
possible before any trust exists — no pinned key, no client cert yet), `token` is this agent's own
existing REST/MCP bearer token (so Bossman knows how to call it back), `address` is optionally
this agent's own reachable `host:port`. A successful response is `{bossman_public_key,
agent_id}` — `bossman_public_key` is Bossman's PEM-encoded PKIX public key, written to disk and
referenced from `tls.trusted_client_keys` so Bossman can subsequently authenticate itself over TLS
client certificates (see `internal/tlsauth`) exactly like a proxy talking to a satellite.

**Deliberately does not auto-edit config.yaml.** `register` writes the fetched public key to a
file (`--trusted-key-path`, default `/etc/agentic-mcp/trusted/bossman.pub.pem`) and prints the
`tls.trusted_client_keys` YAML snippet for the operator to add — round-tripping arbitrary
hand-edited YAML while preserving comments/structure was judged too risky for a first
implementation; safer to have the operator (or a provisioning tool) confirm the change explicitly.

**`--generate-token` is a separate, standalone flag**, not part of `register`: `agentic-mcpd
--generate-token` prints a fresh 32-byte (64 hex char) cryptographically random token via
`crypto/rand` and exits — for bootstrapping a new agent's own `config.yaml` token (or rotating an
existing one) independently of any Bossman interaction. `register` reads this token back out of
the already-loaded config rather than generating one inline, keeping the two concerns cleanly
separate as confirmed with the user.

**Implementation:** new `internal/enroll` package (`Register(ctx, bossmanURL, Request) (Result,
error)`) does the HTTP POST/JSON exchange using the standard library's default TLS verification
(a normal CA-signed or pre-trusted cert on Bossman's enrollment endpoint — there's no pinned key
to verify against yet, since establishing one is the whole point of this call). `cmd/agentic-mcpd`
dispatches `os.Args[1] == "register"` to `runRegister` (its own flag set: `--bossman-url`,
`--enroll-secret`, `--name`, `--address`, `--config`, `--trusted-key-path`) in
`cmd/agentic-mcpd/register.go`; `newBearerToken()` in the same file backs `--generate-token`.

**Verification:** `internal/enroll/enroll_test.go` covers success, wrong-secret rejection, an
empty-public-key response, an unreachable server, and a 500 whose message propagates into the
returned error — all against a real `httptest.Server`, not a mocked interface. End to end: a
minimal mock Bossman (a ~30-line Python `http.server` implementing exactly the
`POST /api/v1/enroll` contract above) was run for real, and the actual `agentic-mcpd` binary was
invoked against it — `register` with the correct secret wrote a real key file to disk and printed
the correct config snippet; the same call with a wrong secret failed with the server's real 401
response propagated into the CLI's error message. `--generate-token` was run twice, confirmed to
produce distinct 64-character hex strings each time.

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

## Roadmap (after this v1 — separate plans)

- **Module completion:** Batch 6 of the `ansible.builtin` coverage plan above (pip, git,
  subversion, unarchive, script, expect, debconf, reboot, package, systemd_service, sysvinit,
  ping). Optionally: multi-task plan/apply (playbook-style) with confirmation — the full Ansible
  replacement
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
- **v3:** mTLS, per-token RBAC (token → allowed tool set), `.rpm`, eBPF expansion (disk I/O
  latency, container awareness)
