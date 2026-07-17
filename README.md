# YOLO-MANager (`agentic-mcp`)

![Yolo Man — Full Managed MCP Server](docs/assets/yolo-man.jpg)

> *"You only live once — but your servers only get one uptime SLA, so let's not get carried
> away."*

A self-contained Linux fleet-management stack that hands your servers' **monitoring**,
**observability**, and **configuration management** to an AI — over [MCP](https://modelcontextprotocol.io)
(stdio or Streamable HTTP) and a plain REST API. No Ansible, no SSH agent, no Python runtime on the
managed host. The node agent ships as a single static Go binary with a hardened systemd unit; the
central Fleet Commander ships as a Docker Compose stack.

Think **CheckMK** (monitoring) + **Coroot** (eBPF observability) + **Ansible** (configuration
management), minus the three separate tools, plus one thing they don't have: an API and a
configuration language built for a language model to actually drive — safely.

**The goal: a server that is completely manageable over one API, in JSON.** Every operation —
monitoring, observability, package and service management, users, storage, network, and running
runbooks — is a JSON request against the agent's unified REST/MCP API. No SSH, no config files to
hand-edit, no separate control planes: the running server's whole state and every action is
expressible as JSON in and JSON out, so a human, a script, or an AI drives it the same way. A
standalone host can be managed directly through the agent's own API (and its embedded web UI);
a fleet is the same API aggregated by Bossman.

Two cooperating components:

- **Duppy** — the node agent (this repo root). Runs on every server. *Duppy* is Jamaican patois
  for a background spirit — coincidentally why Unix daemons are spelled that way. Ours mostly
  watches `/proc` and restarts services on request.
- **Bossman** — the central Fleet Commander ([`bossman/`](bossman/) + [`bossman-ui/`](bossman-ui/)).
  Aggregates the fleet, compiles per-host desired state (GPO-style), translates foreign automation
  (Ansible collections, Checkmk checks) into the agent's sandboxed runtime, and gives an AI one
  endpoint for the whole infrastructure.

---

## Why Starlark, and why NestedText?

Two deliberate language choices sit at the centre of this project. They're worth explaining up
front because everything else — the module library, the checks, the runbooks and roles — is
expressed in them.

### Starlark for logic — "like Ansible, but it runs sandboxed inside the agent"

The built-in modules are native Go. But the *extended* vocabulary — every Ansible collection module
we translate, every Checkmk check, every custom check — is written in **[Starlark](https://github.com/bazelbuild/starlark)**,
the small Python dialect from Bazel. Why not just run Python, or shell?

- **It's a sandbox by construction.** Starlark has no `import`, no filesystem, no network, no
  `os`/`sys`, no ambient authority at all. A module can only touch the system through the
  capability object `ctx` we pass in (`ctx.run`, `ctx.file_read`, `ctx.file_write`, `ctx.stat`,
  `ctx.facts`). You cannot write a module that quietly opens a socket or reads `/etc/shadow` unless
  we handed it that capability. That's the opposite of "curl | bash" or an unrestricted Python
  plugin.
- **It's deterministic and terminating.** No unbounded loops, no recursion, no wall-clock, no
  randomness by default. The same inputs produce the same plan. That's what makes a *dry run*
  (`check_mode`) trustworthy: the preview is the execution.
- **It looks like Python, so an LLM writes it fluently** — but the differences (`== None` not
  `is None`, `fail()` not exceptions, `%`/`.format()` not f-strings) are few, mechanical, and
  enforced by a validator, so a model's output either lint-cleans or gets a precise correction to
  retry against.
- **One validator, one runtime.** `validate ≡ execute`: the Go `starlark-check` binary that gates a
  module is built from the *same* `internal/starmod` package the agent runs it with. A module that
  validates here runs there — they cannot drift.

So a "module" or a "check" is one `.star` file defining `def main(ctx, params)`. Action modules
return `{"changed": bool, "msg": str}`; checks are read-only and return
`{"changed": False, "msg": str, "data": {"state": "OK|WARN|CRIT|UNKNOWN", "metrics": {...}}}`.

### NestedText for configuration — "no quoting, no typing footguns, no YAML surprises"

Every human-authored *configuration* — module metadata, runbooks, roles, provisioning recipes — is
written in **[NestedText](https://nestedtext.org)**, not YAML. NestedText is YAML's readable subset
with the sharp edges removed:

- **Everything is a string, a list, or a dictionary. Full stop.** There is no implicit typing, so
  the [Norway problem](https://hitchdev.com/strictyaml/why/implicit-typing-removed/) (`no` becoming
  `false`, `3.10` becoming `3.1`, `on`/`off`/`yes` surprises) simply cannot happen. A version is
  `"3.10"` because it's *always* text; the module coerces where it means a number.
- **No quoting, no escaping.** A value runs to the end of the line verbatim — SQL, a regex, a shell
  fragment, a password with `:` and `#` in it — no quotes, no backslashes. This matters enormously
  for check thresholds and provisioning commands.
- **Whitespace-only structure, like YAML, so it reads the same** — but the grammar is tiny and
  unambiguous, which means both a human and an LLM produce valid documents on the first try far more
  often.

NestedText carries no behaviour; it's pure data. The *behaviour* is the Starlark. This split —
**declarative data in NestedText, sandboxed logic in Starlark** — is the core of how yolo-man stays
both AI-authorable and safe.

---

## The node agent (Duppy)

Runs on every managed host. Highlights:

- **A full built-in module library, native in Go** — `file`, `copy`, `lineinfile`, `blockinfile`,
  `replace`, `template`, `apt`/`yum`/`dnf`/`package`, `service`/`systemd`, `user`, `group`, `cron`,
  `git`, `unarchive`, `get_url`, `uri`, `iptables`, `reboot`, and read-only facts (`setup`, `stat`,
  `find`, `service_facts`, `package_facts`, …). Idempotent, `check_mode`-aware, `changed: true/false`
  reporting — no Ansible on either end. Every module names its Ansible/Chef/Puppet/Salt/Terraform
  equivalent so an AI can translate from any of them without external docs.
- **A sandboxed Starlark module runtime** (`internal/starmod`) with a `json` builtin, an
  `isinstance` shim, and the `ctx` capability API — Bossman pushes translated collection modules and
  checks here (`POST /api/v1/modules/apply`), and they run by name via `POST /api/v1/tools/{name}`.
- **Nagios/CheckMK-compatible custom checks** — drop in any Nagios plugin or Checkmk local check
  with no rewrite. The `check_plugin` wrapper **auto-detects** which convention the command's output
  follows (Nagios exit-code + `text | perfdata`, Checkmk local `status item perf details` lines, or
  Checkmk `<<<agent>>>` sections) and normalizes it to the verdict — no need to pick a wrapper.
- **Web shell console** (Proxmox-style) — an interactive terminal for any host, right in the UI's
  Console tab. xterm.js over a WebSocket that Bossman proxies to the agent's PTY running `/bin/login`,
  so you log in with OS credentials in the browser. mTLS + the per-host manage ACL gate it.
- **eBPF observability** (Coroot-style) — TCP connection tracking, process-exec events, disk-I/O
  latency, container-aware, with graceful degradation on older kernels.
- **Local SQLite metrics store** with retention/downsampling and a bulk `metrics_dump` endpoint.
- **PAM login + SQLite-backed per-token/user/group ACL** with a per-tool kill switch, enforced
  identically over MCP and REST. Every mutating action previews in `check_mode` first; real
  execution requires a global `write: true` switch (default `false` — mutating tools aren't even
  registered otherwise).
- **Three modes** — `standalone` (default), `satellite` (Bossman pulls its data), and `proxy`
  (**Selecta** — pulls from satellites over mTLS and re-serves the aggregate). Machine-to-machine
  auth is TLS client certs pinned per caller (the `authorized_keys` model, over TLS).
- **`.deb`/`.rpm` packaging**, a hardened systemd unit, a self-contained embedded web admin UI, and
  structured audit logging (one JSON line per call to journald).

See [`docs/plan.md`](docs/plan.md) for the module-by-module scope and how each was verified.

## Is this actually a good idea?

"YOLO" as an engineering philosophy has a well-earned reputation, and handing infrastructure to an
autonomous agent has its own research trail — [Gartner predicts 40% of enterprises will decommission
autonomous AI agents by 2027](https://www.gartner.com/en/newsroom/press-releases/2026-05-26-gartner-says-applying-uniform-governance-across-ai-agents-will-lead-to-enterprise-ai-agent-failure),
with over-permissioning the recurring root cause. So why point something called YOLO-MANager at your
servers?

Because nothing here is a blind commit to prod. Every mutating action runs first in `check_mode` — a
full dry-run preview — before it's ever allowed to run for real, real execution needs an explicit
`write: true`, there's a graduated per-user/per-token/per-tool ACL with a kill switch, and every
call is audited to journald. The Gartner finding — that governance fails when it's all-or-nothing
instead of graduated — is more or less this project's whole design brief. Full model in
[docs/plan.md](docs/plan.md#security-model).

---

## The Fleet Commander: Bossman

![Bossman — Linux Solutions](docs/assets/bossman.jpg)

Bossman aggregates the fleet and gives an AI (and you) one place to run it. What it does today:

- **Fleet inventory & monitoring** — hosts, services, metrics, problems, downtimes,
  notifications, availability, dependency/topology graphs. eBPF "top talkers" reverse-resolve their
  destination IPs to hostnames.
- **The server as one document** — every host compiles to a single `desired_state` JSON: its OU,
  monitoring (checks/thresholds/notifications), orchestration (roles/plans), the GPO-resolved
  **managed config** (per-key winning source), and a full **inventory** tail (OS/kernel, hardware,
  network, and the installed-package list). It's what the AI reads for analysis and what the
  gpresult-style report on each host renders.
- **Policy & Orchestration (GPO-style)** — an **OU tree** (LDAP-style, ltree-backed), first-class
  **host groups**, and **orchestration plans/roles** you bind to an OU / group / host. Per-host
  desired state is compiled with real GPO precedence (`global < group < OU(root→host) < host`),
  `enforced` links, and block-inheritance — resolved server-side, previewed before it's pushed.
  Fleet-wide check thresholds ship as an auto-created **Default Policy** rather than nameless globals.
- **Management console (MMC-style)** — each host's Management tab is a console: a snap-in tree
  (Roles & Features, Services, Updates, Logs, Accounts, Network, Firewall, Storage, …), the
  selected panel in the middle, an Actions pane on the right.
- **Roles & Features installation wizard** — like Windows Server Manager's "Add Roles and
  Features": pick server packages, configure each through a generated input mask (every setting
  shown with its description **and default value**), preview as a dry run, then install — all in
  the console. Each configurable package ships a seeded `install-<pkg>` runbook (install → render
  config from its template → validate → enable/restart service) with a typed parameter schema;
  works across Debian and RedHat via a per-family package catalog.
- **Config management with drift enforcement** — a gpedit-style editor (categories → files →
  settings) authored from the codec registry; a key with no policy is **host based** (the host's own
  value stands). Managed files are **auto-enforced every poll**: an out-of-band change is overwritten
  back to desired and recorded as a roll-backable generation. Config **templates** (apache2 vhost,
  chrony, …) are also usable from a runbook via a `config_template` step.
- **Security** — the fleet's pending package updates organised by **package → the CVEs it closes**,
  each with severity, a plain-language description (Debian tracker) and a link, plus bulk security
  updates across the affected hosts.
- **Checks subsystem** (see below) — a flat `checks.d` library of monitoring checks, assignable to
  host/group/OU with per-scope thresholds, with auto-discovery and credential provisioning. State
  checks (a service is running or not) drop the meaningless comparison/warn-crit inputs.
- **Agent-less devices** — SNMP gear and SSH-only hosts monitored via a co-located poller, presented
  as monitored hosts.
- **Visual workflow designer** — a drag-and-drop runbook builder whose toolbox is searchable across
  the whole module catalog.
- **Users & Access** — human users (admin/operator), machine API tokens, and per-host/group
  **access grants** (admin manages everything; operator/token only what a grant covers).
- **AI chat console** — Claude CLI, ChatGPT Codex, or a self-hosted model, agentic (the model calls
  fleet tools), rendering Markdown + PlantUML/diagrams and a generative dashboard.
- **The translator** — pulls Ansible collections and Checkmk checks through an LLM
  (`llamacpp03/qwen79b`) into the agent's Starlark runtime, validated by the same `starlark-check`
  gate the agent uses.

**Try the whole stack locally** — Postgres/TimescaleDB, migrations, an `admin`/`admin123` seed user,
the FastAPI backend, and the Angular frontend behind nginx:

```bash
docker compose up -d --build
```

Open the URL `docker-compose.override.yml` publishes for `bossman-ui` (`4201` by default) and sign
in with `admin` / `admin123`.

### Checks: translated + custom, all in `checks.d`

A **check** is a read-only Starlark module that gathers data on the host and reports a verdict
(`state` + `metrics`), plus a **discovery mode** (`params._discover`) that enumerates the items a
host has for it — one per filesystem, per file, per sensor — exactly like a Checkmk
`discovery_function`. All checks live flat in `configs/checks.d/<name>.{star,nt}`:

- **Translated** — Checkmk's ~1400 built-in checks, machine-translated to Starlark.
- **Custom** — hand-authored, and crucially **Nagios- and Checkmk-compatible**: the `check_plugin`
  wrapper runs any external check and **auto-detects** the output convention — Nagios (exit code +
  `text | perfdata`), Checkmk local (one `status item perf details` service per line), or Checkmk
  `<<<agent>>>` sections — normalizing each to the verdict. (The `nagios_plugin` / `checkmk_local`
  wrappers remain for forcing one specific format.) Reuse existing plugins unchanged.

Assign a check on the **host's Checks tab** or, GPO-style, to a **group/OU in OU / Policy** — a
host's own config overrides the inherited one, warn/crit levels merged weakest→strongest.
**Auto-discovery** runs the checks' discovery on a host and proposes assignments; when a check needs
credentials (e.g. a MySQL monitoring user), a **provisioning recipe** (`<name>.provision.nt`) creates
the account on the host and stores the generated credential — the admin credentials are used once and
never persisted. The AI can drive the whole flow and **asks you for any required parameters** before
assigning.

---

## Working with NestedText: runbooks and roles

> **Status: proposed format, under active design.** The examples below show where the NestedText
> runbook/role format is heading — Ansible-shaped but flatter and quoting-free. See
> [`docs/nestedtext-playbooks.md`](docs/nestedtext-playbooks.md) for the agent-side NT playbook CLI
> that exists today, and the "NT format" discussion in the project notes for the open questions.

### A runbook

A **runbook** is an ordered list of named steps; each step is one module call. Like an Ansible
playbook, but every value is plain text (no quoting, no `yes→true` surprises) and the structure is
flatter.

```nestedtext
name: web baseline
targets: group:web-servers
steps:
  -
    name: install nginx
    module: apt
    args:
      name: nginx
      state: present
  -
    name: drop the vhost config
    module: config_template
    args:
      template: apache2
      dest: /etc/apache2/sites-available/site.conf
      vars:
        server_name: example.com
  -
    name: enable and start nginx
    module: service
    args:
      name: nginx
      state: started
      enabled: true
```

Run it dry (preview) then for real:

```bash
yolo-man runbook run web-baseline.nt --host web01 --check   # dry run: shows exactly what would change
yolo-man runbook run web-baseline.nt --host web01           # apply
```

The agent's own facts (hostname, distribution, and hardware/DMI like the
motherboard vendor) are available as magic variables — `${inventory_hostname}`,
`${yoloman_distribution}`, `${yoloman_board_vendor}` — with no declaration.
Every run is recorded as an audit trail (visible in the UI's runbook editor).

### A role

A **role** bundles what a *kind of host* should be — its steps **and** the monitoring and
notifications that come with it ("what is orchestrated is monitored"). You bind a role to an OU,
group, or host; Bossman compiles it into the host's desired state.

```nestedtext
role: mysql_server
description: A MySQL database server — package, service, monitoring, alerting.
parameters:
  bind_address: 127.0.0.1
  monitor_user: monitor
steps:
  -
    name: install mysql-server
    module: apt
    args:
      name: mysql-server
      state: present
  -
    name: ensure it is running
    module: service
    args:
      name: mysql
      state: started
      enabled: true
monitoring:
  checks:
    - mysql
    - disk
    - cpu_loads
notifications:
  routes:
    - dba-oncall
```

Bind it in OU / Policy (e.g. to an OU **Databases**), and every host placed there installs MySQL,
gets the `mysql`/`disk`/`cpu_loads` checks, and routes alerts to `dba-oncall` — with per-host
overrides where you need them.

---

## Build, run, test

```bash
# Node agent
go build -o bin/agentic-mcpd ./cmd/agentic-mcpd
./bin/agentic-mcpd --config configs/config.yaml        # MCP (HTTP) + REST
./bin/agentic-mcpd --stdio --config configs/config.yaml # MCP over stdio
go test ./...

# The Starlark validator (used by Bossman's translator + check library)
CGO_ENABLED=0 go build -o bin/starlark-check ./cmd/starlark-check

# Bossman stack
docker compose up -d --build
```

Without a config file the agent falls back to built-in defaults (`127.0.0.1:8010`, write disabled).

## Learn more

The full design — architecture, module system, security model, the three operating modes, the
policy/orchestration compiler, and the complete roadmap — lives in [`docs/plan.md`](docs/plan.md).
