# UI parity matrix & walkthrough findings (F0)

Living document. Rule: **a backend feature is DONE only when its row here is
filled in (or deliberately marked n/a).** Every agent capability gets four
surfaces:

1. **Host facet** — a host-detail tab/section to view + operate it per host
2. **Fleet aggregation** — a cross-host view, where meaningful
3. **Policy scope** — distributable as desired state over OU/group (GPO)
4. **Chat/MCP tool** — the AI console can do it too

Walkthrough basis: full Playwright pass over all 18 screens + 10 host-detail
tabs + 8 Management sub-tabs against the live stack (2026-07-15, docker-test).

## Parity matrix

| Capability | Host facet | Fleet aggregation | Policy scope | Chat/MCP | Notes |
|---|---|---|---|---|---|
| Metrics/monitoring (services, perf-o-meter) | ✅ Services tab | ✅ Fleet Overview, Problems | ✅ check_rules via OU console | ✅ | reference implementation |
| Processes + systemd control | ✅ Processes tab | n/a | n/a | ✅ | |
| eBPF (latency, connections) | ✅ eBPF + Relationships | ⚠️ Topology shows 0 edges (F-3) | n/a | ✅ | |
| Inventory (DMI/OS/disks) | ✅ Inventory tab | ❌ no fleet inventory/search | n/a | ✅ | fleet-wide inventory query = later |
| Network / Firewall / Storage / Accounts / FreeIPA / Updates / Logs | ✅ Management sub-tabs | ❌ | ❌ | ✅ | Cockpit-adaptation plan exists (separate) |
| Plans/orchestration (roles, links) | ✅ Runs tab, placement panel | ✅ Plans, Runs, Deploy | ✅ OU/Policy | ✅ | |
| Check-rule thresholds (GPO) | ⚠️ only in Host placement panel | ❌ | ✅ OU console, **now multi-OU** | ✅ | not on host detail (F-4); multi-OU done |
| **Observed state (server document)** | ✅ **Management ▸ Configuration (F1 done)** | ❌ | — | ⚠️ agent-only | read side live |
| **Generations / diff / rollback** | ✅ **Management ▸ Configuration (F2 done)** | ❌ drift dashboard | — | ⚠️ agent-only | live-verified |
| **Config codecs (structured /etc editing)** | ❌ | n/a | ❌ | ⚠️ raw tool call | **F4** |
| **Config templates (17, schema.json)** | ❌ apply-to-host | ❌ no catalog page | ❌ as policy | ⚠️ raw tool call | **F3** |
| **Piggyback guests/sources (docker/proxmox/vsphere/libvirt)** | ❌ Virtualization tab says "none" while Docker runs | ⚠️ guests appear as hosts only | ❌ | ❌ | **F5** |
| Runbooks (runner) | ⚠️ no host runbook history | ⚠️ text editor only, SWD builder only in agent-ui | ❌ schedule/target | ✅ | F6 |
| Checks library (checks.d) | ⚠️ Checks tab (assignments only) | ✅ catalog (744/1050 in "Other") | ✅ | ✅ | naming collision, see F-4/F-13 |

## Findings (walkthrough 2026-07-15)

### Bugs
- **F-18** Agent self-corrupted its config: docker-test's
  `/etc/agentic-mcp/config.yaml` lost its `tls.cert_file`/`tls.key_file` lines
  (and re-gained a `trusted_client_keys` entry), so the agent crash-looped on
  `tls.enabled requires tls.cert_file and tls.key_file` (restart counter 209,
  down since 15:15). The cert/key files still existed. Something re-rendered the
  config without preserving those fields — likely a `config`/desired-state apply
  round-trip. **Repaired manually** (restored the tls block to enabled + cert +
  key + trusted_client_keys:[], agent active again); the config-rewrite path
  that dropped them needs fixing so it can't recur.
- **F-1** ~~Host-detail Overview throws `null[0]` 4–6× on every visit.~~
  **FIXED**: root cause was mat-tabs rendering EAGERLY, so echarts charts in
  hidden (0×0) tabs initialised with a null zrender transform (`za(r,e)` matrix
  copy) → crash. Wrapped every host-detail tab in `<ng-template matTabContent>`
  (lazy) — charts now instantiate only when their tab is opened + sized. 0
  console errors; also a perf win (10 tabs no longer all render on open).
- **F-2** Fleet Overview: **"Service states" dashlet renders empty** (label,
  no content). ✅ RESOLVED — not a code bug: the donut renders fine live
  (OK/UNKNOWN slices + legend); the empty impression in the walkthrough came
  from a moment with no service data. Verified via Playwright screenshot.
- **F-3** Topology / Relationships: map header says **"0 edges"** while the
  eBPF connections table directly below is full — external destinations
  (LDAP/Kerberos servers) never become nodes/edges; only agent↔agent would.
- **F-16** Management → Network shows provider "NetworkManager" on
  docker-test — verify provider detection (host was believed ifupdown).

### Concept gaps (the "not thought through" feeling)
- **F-4** **Three notions of "checks" with no cross-links**: Services tab
  (from check_rules) says 14 services checked; host Checks tab says "No
  checks apply to this host yet"; OU threshold policies appear only in Host
  placement. A user cannot answer "why is this service checked / where is
  its threshold from?" on the host itself.
- **F-5** Modules page says **"checkmk 0 / 1444 translated"** while the
  Checks catalog shows 1050 translated checks — two bookkeepings (modules.d
  vs checks.d) visibly contradict each other.
- **F-6** **Runs fragmentation**: nav "Runs" → page "Plan Runs" (plans only);
  runbook runs only as a mini-list on the Runbooks page; host Runs tab also
  plans-only. ✅ RESOLVED — fleet Runs page unified (plan+runbook+deploy with
  a type filter); host Runs tab unified too (plan+runbook scoped to the host,
  type filter; deployments stay fleet-level as multi-host aggregates).
- **F-7** **Server-document loop has zero fleet-UI surface** (observed /
  plan / apply / generations / rollback exist only in the standalone
  agent-ui). The flagship feature is invisible.
- **F-8** 17 config templates + codec registry have **no UI at all**.
- **F-9** Virtualization tab: "hypervisors: none — no local virtualization
  stack" although Docker runs and the piggyback Docker collector reports
  containers as hosts. Piggyback sources are neither visible nor
  configurable anywhere.
- **F-10** Runbooks: fleet UI is text-only (Ansible task YAML); the visual SWD
  builder exists only in agent-ui. Library empty ("No saved runbooks").

### Data hygiene
- **F-11** Test artifacts in the prod DB: users `u-8afb94`/`u-ecca9b`
  (**role admin!**), plans `plan-b13112ea`/`plan-d947b466` (the "(unlinked)"
  cards on OU/Policy), runbook runs named `c`,`o`,`p`,`v`,`j`. Tests must
  clean up after themselves (or run against a throwaway DB).
- **F-12** Default memory check_rule warn=10/crit=20 (%) is nonsense — the
  cause of docker-test's permanent Memory CRIT (33.7% ≥ 20).
- **F-13** Checks categorization: **744 of 1050 land in "Other"** (71%).

### Polish
- **F-17** Fleet Overview + Problems tables show a service's STATE (CRIT/WARN)
  but not the value or threshold that tripped it (e.g. docker-test Memory CRIT
  gives no "33.7% ≥ 20%"). Add the value/threshold to the row. (Bugfix batch.)
- **F-14** Hosts list: update/delete actions are raw emoji "⬆🗑" (vs
  Material icons everywhere else); acl host's Services cell is blank (not
  "—"/0). ✅ RESOLVED (icons) — update/delete now use mat-icon
  (system_update_alt / delete). Services-cell blank is a separate data case.
- **F-15** Security page is manual-only (refresh feed + visit each host's
  Updates to collect) — fine for now, note for the poller.

## Block plan (F1+, for execution)

Order: F1 → F2 → F3 → F7-fixes interleaved; F4/F5/F6 after. Each block:
implement → Playwright smoke → update this matrix → commit (no push without
approval).

- **F1 — Config tab (read)**: ✅ DONE. Bossman proxy `GET
  /agents/{id}/state/observed` (+ /state/generations) added in api/management.py
  next to the tools proxy; AgentClient.state_observed/state_generations. New
  the **Management ▸ Configuration ▸ Settings** snap-in (lazy) renders each discovered config file
  with its path, codec/format badge, and codec-parsed values (or sha256/size
  for opaque, or the read error). Loads on tab open + on deep-link
  (?tab=configuration). Verified live on docker-test (6 files: config.yaml
  yaml, /etc/default/* keyvalue). generations endpoint wired but its UI is F2.
- **F2 — Generations & rollback**: ✅ DONE + live-verified. Same
  Management ▸ Configuration ▸ Settings: generation table (# / applied / hash / resources /
  current badge), "Roll back to #N…" runs a dry-run whose plan is the diff
  (per-file key: before→after), shown in a preview card, then "Apply rollback".
  Bossman proxy POST /agents/{id}/state/rollback + AgentClient.state_rollback.
  Verified on docker-test: 3 generations, dry-run rollback to #2 shows
  `/etc/yoloman-selftest.conf create a: null → "9"`; 0 console errors.
- **F3 — Template catalog** ✅ DONE: new Setup page **Templates** listing
  `configs/config_templates/` (needs a small Bossman endpoint serving the
  catalog); `schema.json` → auto-generated form, live render preview
  (template_render dry-run via tools proxy), "apply to host" writing dest;
  per-host entry point from Management ▸ Configuration.
- **Bugfix batch (with F1)**: F-1 null-chart crash, F-2 empty dashlet,
  F-12 memory defaults (warn 80/crit 90), F-14 icons, F-11 cleanup script
  (`scripts/cleanup_test_artifacts.py` — delete u-*/plan-*/1-letter-run
  artifacts after confirmation).
- **F4 — Structured config editor**: edit a discovered config file via its
  codec (form for keyvalue/ini; JSON editor for json/yaml/xml), plan →
  apply via the config module (dry-run first), wired to generations.
- **F5 — Piggyback surface** ✅ DONE (surface; live data needs collector+guests): Virtualization tab: show collectors + their
  guests (also "Docker: N containers"); config editor for
  `piggyback:` agent config (via config module); fleet: guests already
  appear in hosts/overview — link guest → parent.
- **F6 — Runs unification** ✅ DONE (SWD builder port deferred): one Runs page with a type
  filter (plan | runbook | deploy), same on the host Runs tab; port the
  SWD visual builder from agent-ui into the fleet Runbooks page (shared
  lib in the workspace).
- **F-4/F-5 concept fix (with F6)**: host Checks tab gains "effective
  monitoring" summary (check_rule thresholds + library assignments with
  origin/GPO source, link to OU console); Modules page checkmk row links to
  the Checks catalog instead of counting 0.

Deliberately NOT now: fleet-wide inventory search, Cockpit network/storage
deep adaptation (own plan), Security poller automation.
