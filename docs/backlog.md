# Backlog — open tasks

Running list of open work, so nothing is lost between sessions. Newest themes
on top. See docs/ui-parity.md for the original walkthrough findings and
[[project-*]] memories for the standing decisions.

## SNMP / off-host monitoring (active feature — "dummy poller agent on Bossman")

Decision: a normal agentic-mcpd co-located with Bossman polls agent-less
devices (SNMP/SSH); see the `project-ssh-snmp-checks` memory.

- **Block 1 — poller agent in the stack.** ✅ DONE (compose service
  `bossman-poller`, zero-touch enroll, polled 200 OK).
- **Block 2a — Starlark check execution.** ✅ DONE (Bossman-driven, not an
  agent loop): the poller now pushes a host's assigned checks to the agent and
  invokes each in normal mode each cycle, upserting a Service from the result
  (services/monitoring.py `evaluate_assigned_checks`). Distribution = the push
  per poll; no separate agent-side loop needed. This also fixed the "assigned
  check never appears in Services" bug and unblocks 2b/3 (an SNMP check
  assigned to the poller with target/community params will now run).
- **Block 2b — parameterize SNMP checks.** ✅ DONE — solved without touching the
  root-owned `.star` files: `parameterize_snmp_star()` rewrites the argv IN
  MEMORY at push time (community/target from the check's params, injected after
  `def main`; no params → localhost/public so a normal host is unchanged),
  applied in `evaluate_assigned_checks`. So an SNMP check assigned with
  {target, community} now polls that device.
- **Block 3 — SNMP device model + UI.** ✅ DONE — an SNMP device is a satellite
  Agent row (parent = the poller, no address/token, `agent_metadata.kind=snmp`
  + target/community). The poller's `_poll_snmp_device` runs the device's
  assigned SNMP checks THROUGH the co-located poller agent (extra_params merges
  the device's target/community; Block 2b retargets), attributing Services to
  the device — so it shows up as a monitored host. API: `/api/v1/snmp-devices`
  (list/create/delete); UI: Setup → SNMP devices (create form with the 630
  SNMP-datasource checks + a device table linking to the host). Verified live:
  created via UI, appears as a host, poller runs the check + attributes a
  Service. Fixed en route: the poller's own write gate was off (module delivery
  403) → poller entrypoint now writes `write: true`; and monitoring.py had no
  `logger` (its assigned-check except-paths would NameError) → added.
  v3 creds not modelled yet (v2c community only).

## qwen79b batches — now a systemd user service ([[project-config-batches]])

- ~~**Codecs / Templates** — confirm finished.~~ ✅ DONE — both run as the
  `agentic-config-batch.service` systemd user unit (Restart=always, linger, so
  they survive reboot) via `scripts/config-batch-supervisor.sh`; the passes are
  resumable/idempotent. State: 114 configs classified (LLM universe exhausted
  for installed packages), config_templates filled for the codec:"none" files
  (a few like corosync.conf have no man page → skipped). Logs in
  `~/.local/state/agentic-batches/`.

## Checkmk translation tail

- **Non-Windows stragglers** — mostly cleared (now 1440/1444). `smart_stats` +
  `vms_queuejobs` were already present; `printer_supply`, `ucd_mem`,
  `wut_webtherm_humidity` translated 2026-07-16 via `translate_checkmk.py
  --only`. **`wlc_clients` still fails validation** — qwen emits a Starlark
  list-comprehension with a syntax error (`got for, want ','`); needs a
  hand-fix or a different prompt. The rest of the missing are Windows checks.
- **Windows client** (PowerShell modules) — the remaining hard checks
  (`winperf_*`, `wmi_cpuload`, `w32time_*`) belong there, not the Linux agent.
  See the `project-windows-client` memory.

## AI / MCP-skill capabilities (vision — new)

The AI must, exposed **as an MCP skill**:
- **create its own policies** (config policies, thresholds, …) — the K4/K5
  endpoints exist (`/config-policies`, check rules); wire them as MCP tools
  the assistant can call;
- **debug across signals**: pull in policies + **logs (from the host
  overview)** + config settings, diagnose, and **correct** config/policy when
  it finds the cause.

## Open UI-parity findings (docs/ui-parity.md)

- ~~**F-3** Topology "0 edges" — external destinations (LDAP/Kerberos) never
  become nodes/edges.~~ ✅ DONE — the graph only drew agent↔agent edges, but a
  real host's traffic is almost all to non-enrolled services; docker-test had
  226 external host_edges and 0 internal → "0 edges". topology_graph now
  synthesises one node per external IP (loopback excluded, busiest 40 kept +
  logged) with a service hint from well-known ports, and an aggregated edge per
  talking agent. Verified live: docker-test's DCs show as "192.0.2.98 · Kerberos,
  LDAP" etc. — 7 external nodes, 7 edges. UI draws them as neutral slate diamonds.
- ~~**F-4** Three notions of "checks" with no cross-links (Services vs Checks
  tab vs OU thresholds) — "why is this service checked / where's its
  threshold from?" unanswerable on the host.~~ ✅ DONE (see docs/ux-workflows.md
  §2) — Checks tab now lists the host's live Monitoring services with links to
  their thresholds; F-17 further shows the actual warn/crit each is graded on.
- ~~**F-5** Modules page "checkmk 0 / 1444 translated" contradicts the Checks
  catalog count — two bookkeepings; reconcile now that categorization is done.~~
  ✅ DONE — Modules excludes checkmk checks and links to Checks with the real
  count; filter chips count only real modules.
- ~~**F-8** Codec registry still has no UI (config-templates page exists; codecs
  don't).~~ ✅ DONE — new read-only catalog at Setup → Config codecs: GET
  /api/v1/config-codecs serves configs/config_codecs.json (mounted into the
  bossman container) as a flat, searchable list grouped by codec, with a detail
  pane (comment/separator syntax, confidence, covered paths + packages).
  Verified live: 114 patterns (63 keyvalue, 22 ini, 22 none, 6 xml, 1 toml).
- **F-9** Virtualization: piggyback sources not visible/configurable. ⏳ PARTLY
  DONE — **visible**: the agent now exposes GET /api/v1/piggyback/sources (each
  Collector gained a Source() descriptor); Bossman proxies it at
  /agents/{id}/piggyback/sources; the host Virtualization tab shows a "Piggyback
  sources" table (type, target, reports containers/VMs, live reachability +
  guest count) even when the host runs no local hypervisor. Verified live:
  docker-test shows the docker source (socket, reachable, 1 guest). Agent 0.49.0.
  **Still open — configurable**: adding/editing remote Proxmox/vSphere endpoints
  (credentials → write the agent's piggyback config + restart) needs secret
  handling; deferred as its own block.
- ~~**F-10** Runbooks: port the visual SWD builder from agent-ui into the fleet
  Runbooks page (currently text-only NestedText).~~ ✅ DONE — the fleet runbook
  editor now has a Text ⇄ Visual toggle. Visual mode is the Sequential Workflow
  Designer (module/set_fact/debug steps, per-step module/args/when/register
  editors) ported from agent-ui; every edit serialises the definition into the
  same Monaco NestedText the existing lint/dry-run/apply/save read (Monaco stays
  the single source of truth; visual is an authoring overlay, one-way
  visual→text). SWD CSS added to the bossman-ui build. Verified live via
  Playwright: designer + toolbox render, no console errors.
- ~~**F-12** Default memory check_rule warn=10/crit=20 (%) is nonsense.~~ ✅ DONE
  — the seeded defaults are Memory/Disk warn=80/crit=90, Disk IOPS 5000/10000
  (`_DEFAULT_CHECK_RULES`); verified against the live DB, no 10/20 rule exists.
- ~~**F-15** Security page is manual-only (no scheduled CVE poll surfaced).~~
  ✅ DONE — the scheduled poll already existed (cve_feed_loop + after_refresh
  per-host collect), it just wasn't visible. feed-status now also returns
  last_run_started + interval_hours, and the Security page shows a status line:
  enabled/disabled, cadence ("every 24 h"), last refresh time, ok/error, and
  advisories cached — so an operator can see the poll is scheduled (and whether
  it's turned on: cve_feed_enabled defaults off) instead of only having the
  manual "Refresh CVE feed" button.
- ~~**F-16** Network provider detection (NetworkManager reported on docker-test,
  believed ifupdown) — verify.~~ ✅ DONE — real bug: NetworkManager was running
  but every real NIC was STATE=unmanaged (ens18 is driven by
  /etc/network/interfaces); the detector returned "networkmanager" on "running"
  alone, so nmcli config would have been a no-op. `_detect_provider` now also
  requires `_nm_manages_real_iface` (a device that isn't loopback and isn't
  unmanaged/"externally"). Verified live: docker-test now reports
  `provider = ifupdown` (agent 0.48.0).
- ~~**F-17** Show the value/threshold that tripped a service state in the Fleet
  Overview / Problems rows.~~ ✅ DONE — ServiceOut now carries the owning rule's
  `warn_threshold`/`crit_threshold`/`comparison` (one rule fetch in `_to_view`,
  shared with the K4 value-map lookup). Problems + host Services render the
  humane value plus a "warn ≥ 80 %, crit ≥ 90 %" context line, and the
  perf-o-meter uses the real thresholds (fallback 80/90 for rule-less builtins).
- **ADMX-equivalent**: mine man-page value catalogs (qwen79b) so the GPO
  editor offers full per-directive listbox options, not just boolean families.
  ⏳ IN PROGRESS — the third config layer (per-DIRECTIVE value schema), distinct
  from codecs (per-file grammar) + templates (whole-file render).
  `scripts/mine_directive_values.py` reads each codec'd file's man page and has
  qwen extract per-directive {type, values (enum), default, min/max, description}
  → `configs/config_directives.json`; wired as a 3rd pass in the
  config-batch-supervisor (after codecs/templates). Served read-only at
  `/api/v1/config-directives`; the gpedit `valueOptions()` now prefers the
  catalog (enum's real values / bool) over the yes/no-family guess, with the
  directive's description + default shown in the editor. Verified: sshd_config
  mined = 99 directives, PermitRootLogin -> [yes, prohibit-password,
  forced-commands-only, no]. The supervisor will fill the rest of the ~90
  codec'd files after it finishes the codec/template passes.
