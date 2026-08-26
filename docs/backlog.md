# Backlog — open tasks

Running list of open work, so nothing is lost between sessions. Newest themes
on top. See docs/ui-parity.md for the original walkthrough findings and
[[project-*]] memories for the standing decisions.

## Running the DB-backed tests (2026-08-23)

16 tests "failed environmentally" for weeks because `settings.database_url` defaults to
`localhost:5432` and the only database lives in the compose stack. It is PUBLISHED on 55433, and the settings
prefix is `BOSSMAN_`, so they do run:

    BOSSMAN_DATABASE_URL="postgresql+asyncpg://bossman:bossman@127.0.0.1:55433/bossman" \
      .venv-host/bin/python -m pytest tests/test_relationships_api.py

That found two real defects in tests I had just written (a float compared exactly, and an assertion that only
held because an endpoint had no cap) which the skip would have hidden. Note this is the REAL database — the
tests create and delete their own `owned_name()` rows, but a run of the whole suite against it has not been
tried and should not be assumed safe.

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
- **Block 4 — SNMP v3 (USM).** ✅ DONE (2026-08-08, commit 8fa8b26e). A device
  carries `snmp_version` + the v3 security params (sec_level, sec_name,
  auth_proto/auth_pass, priv_proto/priv_pass, context); passphrases stored in
  device meta, never returned by the API (only *_pass_set). parameterize_snmp_star
  rewrites the check argv to `["snmpwalk"] + _snmp_conn + [oids]` and builds the
  -v3/-l/-u/-a/-A/-x/-X/-n sequence (v2c unchanged); go.starlark.net-safe (list
  `+`, no `[*a,*b]`), unit-tested + ast-verified. Poller threads v3 params through;
  UI form has a version toggle with conditional USM fields.

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

## The Windows agent (decided 2026-08-26, plan in docs/windows-agent.md)

C# / .NET, WMI for the monitoring data, a `powershell` module in a hosted runspace as the action plane, the
Linux module library ported under its EXISTING names, roles and features as desired state via a
`families.windows` block in the package catalogue, and MSI in both directions (the agent ships as one, and an
`msi` module installs them). It implements the REST contract the Go agent already implements, so Bossman
needs no Windows special case.

The two rules that decide the shape: a module name means the same thing on both platforms or it gets a
different name (`cron` -> `scheduled_task`, because the semantics differ; a domain account is not a local
one); and a Linux-only module is LISTED on a Windows host with `supported: false` and a reason, never
missing — an absent entry is indistinguishable from an old agent. Same for `load_average`, which Windows
does not have: reported as a named absence, not as 0.

Not started: no dotnet/pwsh/wix on this dev host, and WMI cannot be tested anywhere but on Windows.

## AI / MCP-skill capabilities (vision — new)

⏳ IN PROGRESS — three MCP tools added (bossman/mcp/server.py), verified live
over the MCP protocol against docker-test:
- **`set_threshold`** — the AI authoring its own monitoring policy (K5): create/
  update a CheckRule (host or global scope, warn/crit/comparison). Idempotent
  (upserts by service+metric+scope) so repeated calls don't pile up duplicates.
- **`get_host_logs`** — read a host's journald log (level/since/unit filters) for
  cross-signal debugging.
- **`diagnose_host`** — the cross-signal snapshot in ONE call: the host's non-OK
  services (each with the value + the warn/crit threshold it tripped, via F-17),
  recent error-level log lines, AND the top processes by CPU + by memory — the
  signals to reason about *why* a host is unhealthy (e.g. attribute a CPU/mem
  alert to the offending process) and decide to correct config
  (`call_agent_tool`), tune a threshold (`set_threshold`), or act on a process.
  All monitoring tools now expose the F-17 thresholds via `_service_view_dict`.
- **`get_host_processes`** — the live process table (top-N by CPU) as a
  standalone diagnosis source.
- **`set_host_config`** (K4) — the AI correcting config through the document
  loop (diffable/versioned/rollback-able, not ad-hoc): converges a file toward
  a desired key→value map via its codec. dry_run=true by default (returns the
  diff), so the AI previews then applies. Verified live: a dry-run against
  docker-test's sshd_config returned the PermitRootLogin yes→no diff.

The AI can now diagnose (diagnose_host + get_host_logs) AND correct (set_threshold
for monitoring policy, set_host_config for config) across signals — the vision's
core loop. Follow-up: OU/group-scoped config-policy authoring as an MCP tool
(the REST `/config-policies` exists; only host-scope is wired via MCP so far).

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
- ~~**F-9** Virtualization: piggyback sources not visible/configurable.~~ ✅ DONE.
  **Visible**: GET /api/v1/piggyback/sources (each Collector has a Source()
  descriptor); the host Virtualization tab shows a sources table (type, target,
  reachability, guest count). **Configurable** (agent 0.53.0): the collector set
  is now a reloadable `piggyback.Store`; POST/DELETE /api/v1/piggyback/sources
  add/remove a remote Proxmox/vSphere endpoint at runtime — write-gated, persist
  to config.yaml (safe now the Duration round-trip is fixed) and reload the
  collectors live, NO restart. Bossman proxies at /agents/{id}/piggyback/sources;
  the Virtualization tab gets an add-source form (type/host/user/password/
  insecure) + per-source Remove. Credentials live in the agent's root-owned
  config.yaml (existing model, no new vault). Verified live: added vpp0221's own
  Proxmox API → reachable, 6 guests, persisted; removed cleanly.
- ~~**F-10** Runbooks: port the visual SWD builder from agent-ui into the fleet
  Runbooks page (currently text-only).~~ ✅ DONE — the fleet runbook
  editor now has a Text ⇄ Visual toggle. Visual mode is the Sequential Workflow
  Designer (module/set_fact/debug steps, per-step module/args/when/register
  editors) ported from agent-ui; every edit serialises the definition into the
  same Monaco buffer the existing lint/dry-run/apply/save read (Monaco stays
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

## Two architecture questions the packaging work surfaced (2026-08-23)

**~~The agent should not ship the whole template catalog.~~ DONE 2026-08-23, and NOT the way this entry
proposed.** The entry called for pushing templates on demand "the way checks are pushed"
(`services/discovery.py` → `POST /api/v1/modules/apply`). Measuring first said something better, and the
correction is the interesting part:

1. **The managed write path never reads that tree.** A template resource carries its Jinja2 source INLINE —
   `internal/state/state.go:43` and `:145` hand the body straight to `template_render`. Bossman renders from
   the document it sent. So the tree exists for ONE consumer: the standalone console, on a host with no
   Bossman — which is exactly the host a push could never reach.
2. **That console can only reach a template something NAMES.** It opens one because a path in
   `config_template_index.json` binds it or a `package_catalog.json` entry references it. Measured: 1037
   index-bound + 472 catalog-referenced = **1050 distinct, 7.2 MB**. The other **4424** are named by nothing;
   no request can return them.

So a delivery mechanism would have been a SECOND way to get a template onto a host, with no caller — the
managed path already carries the body and the standalone path cannot name these. The fix was to stop shipping
what cannot be asked for: `scripts/stage-agent-templates.py` computes the reachable set, **asserts closure**
(a bound path whose body is missing would be offered and then fail on Apply) and records what it withheld in
`configs/config_templates_manifest.json`, which `GET /api/v1/config-templates` quotes.

Measured on the package: **22.5 MB → 15.4 MB**, installed **82.8 MB → 55.2 MB**, files **28 037 → 5 563**.
Closure is re-checked on a real installed host by the install test (every template the installed index binds
has a body), and the agent↔Bossman `/config-fields` differential still AGREES on 199 paths.

The same measurement found the listing endpoint returning **every** template's body in one reply — ~36 MB, on
both sides — while its seven callers each wanted one hard-coded name. Now name + `target_path` only, with
`GET /config-templates/{name}` for the body: **197 KB / 164 ms** for 5474 entries, 8.2 KB for the one a
snapin opens.

*Still open, and smaller than it looked:* Bossman ships the whole tree a second time in its own package
(~36 MB of ~98 MB). That one is correct — Bossman serves the authoring view and must have all of it.

**`host_vars` has two sources of truth.** The database has `scope_vars` (scope_type ou|group|host, GPO-merged
host < group < OU root→leaf by `resolve_scope_vars`) — and beside it `plan_loader.load_host_vars()` reads
`plans_dir/host_vars/<hostname>.yaml`, called from `runbook_exec`, `mcp/server` and `api/deployments`:

    magic facts  <  FILE host_vars  <  DB scope vars  <  explicit request vars

So the file layer is not inert: it outranks the facts and loses to the database, deciding in the middle with
no UI, no audit and no scope. Two ways to the same result, which the project's own rules call a logic error
rather than a preference. It is also how a customer's hostname became a FILENAME in git history
(`docker-test.…yaml`), which is what forced the rewrite. The fix is one import of the existing file content
as `scope_type: host` rows and the removal of three call sites.

## The on-demand qualify endpoint — DONE 2026-08-23, and it had never worked

`POST /api/v1/packages/{name}/qualify` spawned `python -m bossman.tools.qualify_packages --only <name>` and
rebuilt the outcome from a 40-line log tail. It now calls `qualify_one()` in this process. Extracting it
uncovered four defects, three of which returned a plausible answer rather than an error — the kind that
survives because nothing looks broken:

1. **The endpoint was dead.** It guarded on `/app/scripts/qualify_packages.py`, a path that stopped existing
   when the tools moved into the package, so every call returned 500 "qualify scripts not available in this
   deployment". A guard for a file nobody runs is worse than no guard: it fails the working thing.
2. **It reported the wrong answer.** `codec` and `directives_keys` came from `codecs.get("packages", {})` —
   and `config_codecs.json` has no top-level `packages` key; it is keyed by PATH, each entry carrying the
   packages that ship it. So `codec` was always null and `directives_keys` always 0, including for a package
   whose codec the run had just classified. The values were in `process_package`'s return the whole time.
3. **An already-current package was reported as a build.** It fell out of the batch's `pending` list, nothing
   ran, and the caller got `ok: true, template_created: true` — indistinguishable from a fresh build. Now
   `already_current` says so and `?force=true` asks for the rebuild.
4. **THE PACKAGED TOOLS COULD NOT FIND `configs/`.** Every one used `Path(__file__).parents[2]`, which is the
   repo root in the container and ONE SHORT in a checkout — so run from a clone they looked for
   `bossman/configs/config_templates` and died in `iterdir()`. That is why a patched duplicate of each of the
   seven tools still sat in the untracked `bossman/scripts/`, one line apart, with the batch running the copy
   while the product imported the original. `_paths.repo_root()` FINDS the root (the nearest ancestor whose
   `configs/` holds a catalog) instead of counting directories; the seven duplicates are deleted and the local
   supervisors invoke `-m bossman.tools.<name>`. It also fixes `enrich_gates`' `go build ./cmd/render-check`,
   whose cwd was `bossman/` on the host — where `cmd/` does not exist.

And two findings the deletion exposed:

- **Four TRACKED tests were green only because of an UNTRACKED directory.** `test_enrich_gates`,
  `test_batch_verify`, `test_main_config_path` and `test_qualify_enrich` did `import enrich_gates` off
  `bossman/scripts/`. A clone could never have run them. Now they import from `bossman.tools`.
- **The catalog rebuild was half an operation.** `build_package_catalog` regenerates every entry from the
  generators, which do not know the checked RedHat facts — so a rebuild alone STRIPS them. Measured on a real
  run: 24 entries lost their curation, `apache2` lost the package `httpd-core` and both `user` fields, and
  `adminer`'s intentionally EMPTY redhat `config_path` (shipped by nothing, and saying so is the point) was
  replaced by a guessed `/etc/httpd/conf.d/adminer.conf`. The second half, `curate_catalog`, was an untracked
  LOCAL script the batch supervisor called and the product could not — so the batch was right and every
  on-demand qualify de-curated the catalog. It is now in `bossman.tools` and `build_package_catalog.main()`
  calls it: two steps that must always both run are one operation. (`_core_keys()` also stopped REGEXING the
  builder's source file for `^    "name": {"label"` and imports the `CORE` dict instead — that regex returned
  an empty set, silently curating away every CORE decision, the moment the file moved.)

**~~Two writers, two indents~~ DONE 2026-08-23.** `config_codecs.json` and `config_directives.json` were
written from ~17 places disagreeing on `indent` (2 vs 1) AND `ensure_ascii` (True vs False), so the two groups
took turns rewriting 200 000 lines and a one-key change was indistinguishable from a reformat.
`bossman/bossman/tools/_jsonio.py` is the single writer now (indent=2, `ensure_ascii=False`, sorted, atomic)
and all 17 call sites use it. The one-time cost was 918 lines — the 1966 `\uXXXX` escapes becoming readable
UTF-8, which is man-page prose no reviewer could check as `’`. Two things the unification exposed, both from
writing once from the container and then looking: `mkstemp` creates 0600 and `os.replace()` replaces the MODE
with the contents, so the catalogs became root-only and the host user could not even `md5sum` them; and
OWNERSHIP moved the same way, leaving a root-owned file the host batch could no longer update. Both are
carried over now, and five state files damaged before the fix landed were repaired.

**~~The RedHat attestation source is incomplete~~ DONE 2026-08-23**, and the diagnosis was an equivocation
rather than a gap. `curate_catalog` asked `package_universe_real.json["redhat"]` whether an EL package exists.
That record answers a different question: built from two Rocky repos and then FILTERED to
configurable-service candidates, so "absent" meant "not a service candidate in BaseOS or AppStream". Neither
`sssd` (BaseOS) nor `nginx` (AppStream) is in its 1902 entries — `nginx` survived only via the builder's
`CORE` table and `sssd`'s branch was dropped, for the canonical RHEL identity client.
`bossman/bossman/tools/record_el_package_names.py` now measures the real thing in an almalinux:9 container:
**33 898 names** across baseos+appstream+crb+epel, with the repos each name lives in.

And **EPEL does not attest**, deliberately: the question is whether a role's redhat branch is a real
translation or a copied Debian guess, and EPEL answers "can this be installed". Measured, EPEL ships `apt` and
`ufw` — counting it would KEEP exactly the copied branches the pass removes. Attestation is therefore the
distribution's own repos (7477 names) unioned with the old candidate listing, and EPEL is recorded so it can
be STATED. That already corrected a curated claim: "ufw is not packaged for RHEL" was false as written, and a
claim an operator disproves with one `dnf install` costs every other claim here its credibility.

## The man page the batch grounds on is often a navigation stub — FIXED 2026-08-25

`_online_manpage` accepted any fetch over 800 characters. Measured on 15 packages, **7 of 15** came back as
site chrome and passed: manpages.debian.org answers `/ddclient` with a **1548-character index page**,
`/nginx` with 4271 and `/smb` with 4065 — while the real `smb.conf(5)` is **200 kB**.

The grounding gate then does its job perfectly and rejects every correct value the model proposed, because a
table of contents does not contain them. **Not a hallucination — a silent UNDER-grounding** that reads as
"this package documents no values", and part of what earlier in this session looked like a systemd-directive
problem.

Fixed with a length floor (6000 characters; a section-5 page documenting a config file's directives is not
2 kB). It also RECOVERS pages: the loop no longer stops at the first thin hit, so `smb` went from a 4 kB stub
to the real 200 kB page — 9 real pages accepted where 8 were before, and the 6 rejected fall back to the
shipped `.deb` config and the web docs, both better witnesses than chrome.

**No chrome-detection test**, and that is measured too: `manpages.debian.org` wraps EVERY page in the same
navigation, so a version of this gate that rejected on "Skip Quicknav" threw away redis (43 kB), dnsmasq
(138 kB) and ntp (60 kB). Length alone separates them — stubs 1.5–4.7 kB, real pages 12–200 kB.

*A re-run was measured and is NOT worth it.* Controlled A/B over the same 37 templates the stopped laguna pass
had already asked: 8 of them lost their "man page" to the new gate (it was chrome), and the enum yield went
**2 → 2** — one lost (`0xffff/hw_revision`, which had grounded on the stub) and one gained (`agetty`). So the
fix makes the grounding honest without unlocking enums, and a 1214-template re-run at that rate is not
justified. Four minutes of measurement instead of hours of batch.

### What the A/B did find: 497 closed menus built from open sets — FIXED 2026-08-25

`0xffff/hw_revision` got its enum `['2101','2102']` from a description reading **"Hardware revision string
(e.g., '2101,2102')"**. The description extractor REFUSES that — an example is not an enumeration — but the
LLM enum stage has no such gate and ran first. Audited across the corpus: **497 fields** carry a closed menu
whose own description hedges the values.

| field | menu | its own description |
|---|---|---|
| `alien/target_arch` | `all, source, any` | "e.g., 'amd64', 'i386', 'all'" |
| `apcupsd_cgi/syslog` | `daemon, user` | "Common values: 'daemon', 'local0'–'local7'" |
| `0install/…items.type` | `version, trust` | "e.g., 'version', 'rating', 'age', 'trust', 'priority'" |

A syslog-facility dropdown without local0–local7 does not look thin — it makes the needed value **untypable**,
and the write path is whole-file.

**Deleting them would be wrong too**: several are correct sets that happen to be introduced with a hedge
(`ansible_core/defaults_fact_caching: jsonfile|memory|redis|yaml` really is Ansible's set, described as
"Common options"). So the fields are MARKED — `enum_open` travels through both servers into the one form
renderer, which shows an input with a datalist and the note "suggestions — other values are allowed". The
suggestions stay and an unlisted legal value can still be typed.

Also fixed in the same pass: **34 enums containing the same value twice** — `acl/permissions: ['r--', 'r--',
'rw-']`, and busybox's `mdev.conf` uid/gid lists which repeated `operator`, `list`, `proxy` and `backup`
several times each.

## The nine value-set disagreements: 3 settled, 6 abstained — 2026-08-25

Settled against the man page, using the qualify batch's own `_resolve_man` chain (local `man` → man7.org →
manpages.debian.org) so "which man page" cannot have two answers. `tools/settle_value_disagreements.py`.

| | |
|---|---|
| `/etc/default/console-setup` CODESET | settled — `Arm` dropped as a truncation of `Armenian` |
| `/etc/default/console-setup` FONTSIZE | settled — the empty string dropped |
| `/etc/freeipmi/ipmiseld.conf` authentication-type | settled — the union, nothing deleted |
| `/etc/redis/redis.conf` loglevel | settled — the union `debug verbose notice warning nothing`, confirmed by redis.conf's own comments |
| the other **5** | abstained, each naming the unconfirmed values |

**TWO WITNESSES, NOT ONE.** Preferring the man page *because it loaded* was measured to abstain on exactly the
case the config file answers: redis's 43 kB man page contains neither `verbose` nor `notice`, while
`redis.conf`'s own comments list all five. The config the package ships is consulted alongside the man page
now, and a value confirmed by either counts — taking the union can only enlarge the confirmed set, never
delete from it.

Still open, each with its reason recorded: `ddclient.conf protocol` (neither source fetched),
`ipmiseld privilege-level` (CALLBACK absent from both), `hostapd hw_mode`, `swaync layer`,
`xrdp security_layer` (x509 absent).

**THE RULE IS UNION-ONLY: NEVER DELETE ON A MISSING WORD**, and it took two wrong versions to get there:

1. The first accepted any grounded subset. On `/etc/ddclient.conf protocol` it settled a 21-value set down to
   `['easydns', 'dyndns']` — deleting `cloudflare` and eighteen other protocols ddclient really supports —
   because the fetched "man page" was the 1548-character stub above and `easydns` happened to appear in its
   chrome. **A confident narrowing from a wrong source is the worst thing this tool could produce.**
2. The second required the settled set to contain one catalog's set in full. That still deleted a real value:
   for freeipmi's `privilege-level` it kept `USER OPERATOR ADMIN` and dropped **`CALLBACK`**, a real IPMI
   privilege level that simply does not appear in `ipmiseld`'s page — while `PASSWORD` and `KEY` "grounded"
   on ordinary English sentences. Absence of a word is not illegality, and prose matching cannot tell.

So the only deletions are the two the page cannot be wrong about: an empty string is not a value, and a value
that is a strict prefix of a grounded one is a truncation. Everything else unconfirmed → abstain, with the
list recorded in `configs/value_set_settlements.json` for a stronger source or a person.

## The four remaining disagreements: 2 settled, and the grounding chain was fetching the wrong documents

Reviewing whether the recorded work is still needed, the four value-set disagreements turned out to be four
DIFFERENT cases, which is why no blanket rule had settled them. Grounding each against its own package:

    xrdp.ini  security_layer   the man page writes `security_layer = [tls|rdp|negotiate]`  -> x509 is wrong
    swaync    layer            all four ground in swaync(5)                                -> union
    ddclient  protocol         16 of 21 ground in the shipped sample                       -> abstain
    ipmiseld  privilege-level  NONE of the five appear in an 11 kB page                    -> abstain

**A bracketed enumeration in the option's own definition is a CLOSED set**, and it is the one shape that may
delete. Everywhere else this codebase refuses to narrow on a missing word — an absent word is not an illegal
value — but a page writing `security_layer = [tls|rdp|negotiate]` is not being silent about `x509`; it is
stating the range. That is positive evidence about the SET rather than absence of evidence about a member.
Exactly one of the four had it, and it was the one where a union would have propagated a value xrdp does not
accept into the catalog that had it right.

**And two defects in the grounding chain itself, both found by asking why swaync abstained on a set every
member of which its man page contains:**

- `manpages.debian.org/config` answers with **Config(3perl)** — 412 kB of Perl module documentation that
  sails past the 6000-character floor. Any template whose config file is named `config` had that as its "man
  page", and the grounding gate then dutifully rejected every correct value the model proposed. **85 bound
  paths** have a generic basename, 60 of them literally `config`. A wrong page is worse than no page: the
  result reads as a package with no documented values rather than as a failed fetch. Generic stems are now
  dropped from the candidate list.
- **The Debian URL carried no section**, so a package with both pages grounded against the wrong one:
  `/swaync` returns swaync(1) (the command, silent on every config value) while `/swaync.5` returns the page
  that documents them. `<name>.5` is now tried first.

Budget: value sets that disagree **4 -> 2**. The two that remain are honest abstentions with their reasons
recorded — ddclient's five unconfirmed protocols (`hammernode1`, `dnspark`, `dtdns`, `freedns`, `godaddy`)
are absent from a 10 kB sample that is plainly abridged, and freeipmi documents the option without ever
naming its values.

~~Still open: the 85 paths deserve a targeted re-run.~~ **MEASURED, AND NOT NEEDED** — half an hour after
writing that sentence. If Config(3perl) had cost those templates their enums, they would carry fewer value
sets than the rest of the corpus. They do not:

    the 33 generic-basename templates    573 fields, 36 with a value set   6.3%
    every other template               10 638 fields, 699 with a value set 6.6%

Indistinguishable. The wrong page was rejecting values, but the enum rate is dominated by whether a field is
an enum at all and by the other two witnesses (the shipped config and the documented sample), which were
already being consulted. The fix still matters for every future fetch; the re-run would have bought nothing,
and an LLM batch is exactly the kind of expensive no-op worth not running.

## `True` is sometimes the RIGHT literal — 2026-08-25

Chasing the boolean residue to the end produced a negative result worth writing down, because the next person
will otherwise "fix" it: **13 templates hardcode `True`/`False` in their bodies, and all 13 are correct.**
glances, mopidy, carbon-cache, ceph-mgr-dashboard and every OpenStack `.conf` are read by Python's
`configparser`, for which `True` is the idiomatic literal. Of the 9 reachable templates still rendering one,
four or five are that case.

One was genuinely wrong and is fixed: `realmd.conf`. Its man page shows `fully-qualified-names = no` and
contains **no** `true`/`false` at all, so `use_fully_qualified_names = True` — a literal in the body, not a
substitution — became `yes`/`no`.

The residue is now a watched budget rather than an open question: `check_catalog_fit` counts boolean fields
substituted bare (statically — the exact number needs a render, and a check that needed a Go build would not
run). It is at 0 and **cannot be expected to stay there**; its job is to notice a RISE, i.e. a new template
written the wrong way.

Also corrected: `lower_literal_bools` refused fields used both bare AND in a conditional, reasoning that the
variable would have to be a word in one place and a boolean in the other. That was wrong — piping rewrites
only the `{{ x }}` substitution, while `{% if x %}` is a different occurrence left untouched. The render-proof
pass demonstrated it by fixing 18 of the 20 templates the rule had refused.

## A source nothing had looked at: the package's own documented sample — 2026-08-25

`/etc/hostapd/hostapd.conf` as Debian ships it says almost nothing. `/usr/share/doc/hostapd/examples/
hostapd.conf` is **128 kB and mentions `hw_mode` ten times**. The batch had never looked there — it read the
man page, the working config under `/etc`, and the web — which is part of why "both sources are silent"
happened as often as it did.

`qualify_packages.deb_doc_samples()` extracts them (gzipped included, sorted so a grounding decision cannot
depend on directory order), and both the value-set settlement and the enum/directive mining now see them.
Immediate result: `/etc/hostapd/hostapd.conf hw_mode` settled to the union `a b g be`.

**And the registry often cannot name the package to fetch.** Measured on the unsettled disagreements:
`/etc/ddclient.conf` and `/etc/xdg/swaync/config.json` carry `packages: []`, and `/etc/xrdp/xrdp.ini` carries
`["xrdp.ini"]` — a FILENAME, the 213-entry class `audit_package_claims.py` recorded. So candidates are also
derived from the path (the directory under `/etc`, then the basename without its extension): a wrong guess
costs one failed `apt-get download` and grounds nothing, a missing guess costs the whole witness. With that,
ddclient went from "nothing consulted" to 16 of 21 values confirmed.

Four disagreements remain, each because a value is genuinely absent from every source — `CALLBACK` for
freeipmi's privilege levels, `x509` for xrdp's security layer — and the rule holds: an absent word is not an
illegal value, so nothing is deleted on it.

**The check now runs itself.** `check_catalog_fit` is invoked by the qualify supervisor after every pass
(reported, not fatal — the pass must not stop because a budget grew, but the log has to say so) and by
`tests/test_catalog_fit_holds.py` against the real catalogs. A tool nobody invokes is a rule nobody enforces.

## "Do the three fit?" is now one command — 2026-08-25

`python -m bossman.tools.check_catalog_fit`. Five passes and a nightly LLM batch write the same catalogs, and
every rule the check enforces was learned from a defect that had already reached the editor. It separates two
kinds of finding on purpose:

- **INVARIANT** — must be zero. A value set with fewer than two options, a duplicate, a label for a value that
  is gone, `enum_open` without values, a JSON boolean default on a text field, an unknown type word, a type
  that is not a word, a set that is open on one side and closed on the other, a bound path whose template has
  no body.
- **BUDGET** — cannot be zero yet and must not GROW. Recorded in `configs/catalog_fit_baseline.json`; a rise
  fails, a fall rewrites the file. That is the honest half: "115 templates render a Python-cased boolean" is
  not something to assert away, and a check that only reported zero-or-not would have had nothing to say for
  the two days it took to drive that from 214 to 9.

**Its first run found 19 violations nobody had looked for**, because every previous pass had asked about
values and none about the type:

    designate-agent.conf  description  type = "Port the agent listens on for incoming requests."
    designate-agent.conf  bind_port    type = ":{"
    81voltd               port         type = "number|list"
    pagure_ci             builders.items  type = {"type": "string", "default": "docker", …}

27 repaired by `tools/fix_broken_types.py`, in that order of evidence: a nested spec is UNWRAPPED (the
generator wrote the field twice, so the inner one is the field), a union resolves to its permissive member,
otherwise the JSON type of the field's own default decides, and failing that `string` — which is the control
the editor was already falling back to, now said out loud.

And 4 settings were **open on one side and closed on the other**: `mark_open_enums` works per catalog and
marks whichever side's own description hedges, so the same setting was "suggestions" in one editor and "the
whole range" in the other. Openness now propagates in `sync_value_sets` — a hedge on either side opens both,
because evidence that a set is incomplete does not stop being evidence in the other catalog.

State: **all invariants clear**, settings with a one-sided value set **0** (was 38), value sets that disagree
**5** — each recorded with its unconfirmed values and no source able to settle it.

## Two vocabularies for one thing — DONE 2026-08-25

Auditing type and default agreement between the two catalogs (337 type differences, 639 default differences)
turned up two defects with the same shape: a value that is correct in one vocabulary and meaningless in the one
that reads it.

**427 fields say `type: "boolean"` and 62 say `"integer"`** — JSON-Schema's words, written by the template
generator. The form renderer knows only this project's (`bool`, `int`, `list`), so **every one of them rendered
as a text box where a checkbox or a number field belongs.** Normalised in the two places that already
translate `values`→`enum` and `number`→`int`, and in the template branch too, which returns its schema
properties as they are — that is where the 427 live. A union (`bool|string`) resolves to the permissive side:
a text box accepts everything a checkbox would, not the reverse.

Of the 337 "type differences", **218 were `directive: enum` vs `template: string`** — the same setting, two
conventions, already reconciled at serve time by the values→enum rule. Not a defect; noise in the audit.

**25 fields are typed `string` with `default: true`** — a JSON boolean, which `template_render` substitutes
verbatim, so the file receives `True` with a capital T and shell, INI and YAML parsers alike reject it.
`sample.json` knows what the file wants, and all 25 had a string there:

    heimdal-kdc/kdc_enabled    default True   sample 'yes'    ->  "yes"
    parsec-service/allow_root  default False  sample 'false'  ->  "false"
    apcupsd/nis_enabled        default True   sample 'on'     ->  "on"

The PAIR is learned, not copied: `dyn-netconf/dhcp` has `default: true` beside `sample: 'false'`, so the
sample is an example of the syntax and the truth value still comes from the default. 23 fixed; the 2 whose
sample is not a boolean word (`gallery-dl/zip` → `'gallery-dl-{id}.zip'`, `openssh_client/control_master` →
`'auto'`) are not two-state fields at all, so their default is dropped — an empty field is honest where a
wrong word is not.

## One setting, one value set — DONE 2026-08-25

The larger half of the "do the three fit" question was not the 9 contradictions but the **38 keys where only
ONE catalog had a value set at all**: the same setting was a dropdown in one editor and a text box in the
other, and which one the operator met depended on the codec classification. 39 sets copied across
(`tools/sync_value_sets.py`) — safe in a way deciding is not, because nothing is deleted, nothing invented and
the evidence already existed. `enum_open` and the labels travel WITH the values: copying an open set as a
closed menu would turn "these are suggestions" into "these are the only values".

**And the passes were interacting.** The dry run offered to copy `GLOBUS_GATEKEEPER_LOG_FACILITY:
['LOG_DAEMON']` — a one-option set, out of a catalog whose one-option sets had already been dropped 361 at a
time. Cause: `mark_open_enums` deduplicated `['LOG_DAEMON','LOG_DAEMON']` down to one AFTER that pass ran. Two
correct rules in the wrong order produced the thing both forbid, and it only surfaced because a third pass
offered to spread it.

So the invariants live in one place (`tools/_valuesets.py`) and every writer calls `normalise` last: no
duplicates; fewer than two options is not a choice; **and rule 2 is asked after rule 1**, which is the whole
reason the file exists. Labels and the open mark travel with the values or die with them.

Corpus-wide: **0 one-option sets** remain in either catalog (was 361 + 6), 39 settings that disagreed by
omission now agree, 5 real disagreements remain recorded and undecided.

| | |
|---|---|
| directives | 4392 value sets, 101 marked open |
| templates | 3460 enums, 396 marked open |

## The enum dropdowns: the gap is mostly not a gap (2026-08-23)

"Why are enums still missing when the qualify batch mines them?" Measured, they are not missing wholesale —
the stage ran for 9570 of 9584 packages, and **2843 fields across 1371 templates DO carry an enum**. What was
missing was the REASON for the rest: 25 917 string fields with no dropdown and nothing recorded about why.

`_mine_enums` now writes one reason per field to `configs/schema_enum_abstentions.json` — nothing proposed /
no source contains any proposed value / only one value grounded (not a choice) / the recorded default
contradicts the documented set. With that record, `tools/mine_enum_gap.py` (resumable, one process, laguna)
measured the residue over its first 36 of 1217 candidate templates:

| | |
|---|---|
| the model proposed nothing | **236 of 286 (82%)** — and mostly correct |
| proposed, grounded nowhere | 31 |
| only one value grounded | 13 |
| the schema's own default contradicts the grounded set | 5 |

**Yield: +2 enum fields over 36 templates**, so the pass was stopped rather than run for hours at that rate.

### What actually closed part of it: the description already says the values — DONE 2026-08-23

`tools/enums_from_descriptions.py`. No model, no man page, no web search: the value set was recorded when the
template was generated and never turned into an `enum`.

| | |
|---|---|
| templates with an enum | 1371 → **1622** (25.0% → 29.6%) |
| fields with an enum | 2844 → **3272** |
| existing enums **repaired** (missing values their own description states) | **86** |
| refusals, each with a recorded reason | 25 318 |

The gates are the interesting part, because each is a measured mistake and each cost a count:
**508** fields refused as *examples* ("(e.g., 'amd64', 'arm64')" is an open set — a dropdown from it removes
i386 from reach); the hedge "Common values: …"; two distinct **truncation** bugs (a comma *and* an "or"
before the last item, and a per-value gloss between value and separator — the latter gave
`openssh_server/address_family` `any, inet` for a set that is `any, inet, inet6`); and the stopword list that
was itself deleting `on`, `any` and `default` — the words that most often *are* the values. Idempotent; a
second run adds 0.

### `enum_labels` — DONE 2026-08-25, and the count that matters is 21% of what I was counting

The numeric form (`0=error, 1=warn`) yields the numbers, which is right for the file and a menu of nothing for
the operator. `enum_labels` (value → meaning) now travels from the schema through BOTH servers
(`api/config_fields.py`, `internal/server/management_config_fields.go`) into the one form renderer, which
shows `error (0)` and submits `0`. Extracting the labels found three defects in the extractor, all of the
worst kind — a wrong VALUE:

- **The sign was not part of the number.** `-?` was missing, so `1` was captured out of `-1` and
  `argus-client/ra_print_labels` got the enum `0, 1` for a setting whose legal values are `0` and `-1`.
- **The label was bounded by a character class**, so "Traditional Chinese (Big5)" stopped at "Traditional
  Chinese" and "mm/dd/yyyy" at "mm" — giving `drbl/default_language` two different values the SAME label.
  Labels are now bounded by the next mapping, and duplicates are refused outright.
- **A leaked JSON fragment**: `clsync/clsync_ionice_class`'s *description* ends
  `3=idle).", "enum": ["0", "1", "2", "3"]` — a generation pass wrote its own JSON into the string. Refused,
  and worth a corpus sweep of its own.

**And one tried repair made things worse, which is the lesson.** Re-deriving existing numeric enums from
their descriptions "fixed" four and broke two: `dnssec-trigger/verbosity` lost the legal values 3 and 4
because its description writes them as "3/4 debug" rather than "3=debug", and `sphinx_searchd/binlog_flush`
lost the value 2 that its description simply does not mention. **A description names SOME values; an enum
mined from a man page may know more. Widening is safe, narrowing is a guess with the same shape as a fix.**
Only the sign correction was kept.

**THE MEASURE WAS WRONG.** Of 3431 enums in the corpus, only **708 (21%)** sit on a template that any surface
can open — the rest are on the 4425 templates nothing names (the same set the agent package stopped shipping).
Of the labelled ones, **1 of 14** is reachable. So the honest ADMX-parity number is not "5.3% of all fields"
but:

| on REACHABLE templates | |
|---|---|
| fields | 11 713 |
| with an enum | **708 (6.0%)** |
| string fields | 5834, of them enumerated **707 (12.1%)** |

Which reframed the next step as **reachability** — and measuring that showed the reframing was wrong too.

### The reachability gap is correct — 2026-08-25

"4425 templates are bound by nothing" sounds like 4425 missing editors. Measured, it is not:

| why a template is unreachable | |
|---|---|
| **withdrawn** — the package ships no file at that path (measured) | 1920 |
| no `meta.json` at all, and of those the 370 with a derivable path: 255 measured **absent** | 1751 |
| **lost a path conflict** to a better template for the same file (recorded) | 266 |
| `meta.json` records no `target_path` | 239 |
| has a target, yet nothing binds it | 249 |

Following the last two buckets to their paths: `/etc/cron.daily/acct`, `/etc/init.d/apparmor`,
`/etc/kernel/postinst.d/dracut`, `/etc/pam.d/away`, `/etc/jabber-querybot/Querymodule.pm`,
`/etc/fenrirscreenreader/keyboard/Readme.md`. **205 init/rc scripts, 49 cron fragments, 13 hook scripts, 9 PAM
stacks and 9 documentation files** — for 197 of which the file really exists. Binding those would be the
sshd/pam.d damage class, not a gain.

Of the 102 unreachable templates that DO target a shipped config file, most are duplicates whose path is
already bound to a better template (`conky-cli`, `conky-std` and `conky.conf` all target
`/etc/conky/conky.conf`, bound to `conky-all`) and are recorded as conflicts. After removing withdrawals,
conflicts, scripts and documentation, the **genuine** gap is **26 paths — and 20 of those are still hooks or
scripts**. So roughly six.

**So neither "mine more enums" nor "bind more paths" is the lever, and the corpus is not hiding 4000 editors.**

### What that measurement DID find: 27 live bindings that are not settings — DONE 2026-08-25

The path verdict answers "is there a file", never "is it a SETTING", and those are different questions:
`/etc/cron.daily/logrotate` exists, measures `file`, and is a program. The editor was offering **27** such
paths — 21 in run-parts/hook directories (`/etc/cron.daily/*`, `/etc/X11/Xsession.d/*`) and 6 documentation
files (`/etc/apparmor.d/local/README`, `/etc/arp-scan/mac-vendor.txt`). Configure writes the WHOLE file, so
pressing it on `/etc/cron.daily/logrotate` breaks daily log rotation.

`template_index.unsuitable_target()` now withdraws them with a stated reason, in the same `withdrawn` list the
UI already surfaces — a decision rather than the accident it was, because 225 further templates in the corpus
record such a target and are unreachable today only because nothing binds them, which a later improvement to
the resolver would silently undo.

The line is drawn by DIRECTORY, not extension, and the exclusions carry as much weight as the refusals:
`/etc/cron.d/*` stays (a crontab fragment IS config, unlike `/etc/cron.daily/*` which holds scripts), so do
`/etc/logrotate.d/*`, `/etc/apparmor.d/*.profile`, and configuration written in a programming language —
`config.inc.php`, `prosody.cfg.lua` and `LocalSettings.php` are how those applications are configured, and a
rule refusing `.php` would delete correct bindings to win an argument about file names.

Verified: 1538 paths bound, 27 withdrawn as `not-configuration` with their reasons in the index the UI reads,
`/etc/cron.daily/logrotate` no longer bound while `/etc/cron.d/anacron` still is, `/config-fields` for a
withdrawn path falls back to `freeform` instead of offering a whole-file render, and the agent↔Bossman
differential still agrees on 198 paths after re-exporting the projection.

Two findings from the LLM pass are worth more than the enums it would have added:

- **The 2072-field "gap" is over-selected by the name heuristic.** `cache_dir`, `feeds.items.url`, `*_version`
  are genuinely free text, which is why 82% got no proposal. The gap is real but much smaller than 2072.
- **The recurring names are SHARED, and their documentation is not in the package's man page.** `log_level`
  appears in **302** templates, `log_format`/`syslog_facility`/`log_facility` in 58; and the 31 that grounded
  nowhere are systemd unit directives (`restart_policy`, `protect_home`, `protect_system`) whose value sets
  are real and are documented in `systemd.exec(5)`. Asking a package's own man page about them 302 times
  cannot work. **Next step: one grounded vocabulary of recurring directive value sets, fetched once from the
  source that documents each, applied by name** — grounded, not model knowledge, with the man page recorded
  as the witness. That is the ADMX-parity work, aimed at the 30% of fields that 22 names cover.

Also visible in the record and not yet acted on: **five schemas whose own `default` contradicts their
declared type** (`rd_mode`: `type: "string"`, `default: False`; `rd_flags`: `type: "string"`, `default: []`).
Those are broken schema entries, not enum problems, and the record is the first time they were countable.

## Host page payloads — DONE 2026-08-23, and what it left open

The note this replaces said "the Overview loads too slowly, serve it from the DB instead of a live
pass-through". Measured in the browser, that was the wrong diagnosis: the observed-state cache had already
landed (15 ms), and the same endpoints answer in 16–97 ms asked alone while taking 930–1029 ms on first load.
The causes were payload and fan-out, not query cost — `relationships` at **5.46 MB**, the whole fleet table
fetched to render one row, and a tab's data fetched for every visitor. Result: **5.06 MB → 109 KB**, last call
**1162 ms → 506 ms**. Details in commit 36d3ab47.

Still open from that work:

- ~~**The poller records one permanent row per ephemeral destination port.**~~ **DONE 2026-08-26**, and the
  three days of waiting cost 45 032 rows: 28 203 → **73 235 rows / 84 MB**, 96.7% of them a single connection
  to a peer's random high port, `pveproxy worker -> 127.0.0.1` alone holding 42 348 over 14 116 ports.

  Both halves of the recorded question turned out to have an answer. **Aggregation**: a high port that is one
  of eight or more at the same address is a *client* port — a service does not live on eight random high
  ports of one address, a client does exactly that. Evidence from the rows themselves, so no port list to
  maintain, and it keeps mysqlx (33060) and the gRPC ports a numeric `>= 32768` rule would have destroyed:
  the 11 groups that collapse hold 42 310 of the 42 609 ephemeral ports. **Retention**: `host_edges` is a
  plain table and had none at all, while the agent prunes its own edges at 24h — so Bossman kept asserting
  relationships its own source had forgotten. 30 days now, in `run_housekeeping`.

  73 235 → **2 710 rows, 84 MB → 688 kB**, and the 13 folds are named (`client_ports: true`, null port,
  "client ports" in the table) rather than shown as a port 0 nothing can listen on. The event counts survive
  the fold; what did NOT survive is reading them as lifetime totals, and that reading was itself the bug's
  artifact — the agent's counter restarts whenever the agent forgets an edge, so every row here has always
  meant "what the source currently reports".
- ~~**The agent still keeps and ships the un-collapsed rows.**~~ **DONE 2026-08-26** — the same rule now runs
  in `internal/store.foldClientPorts`, on the retention cadence (hourly) next to `pruneEdges` rather than in
  `UpsertEdge`: that is the hot path, one call per connection event out of the eBPF ring, and it must not
  grow a query. Rows accrue between passes, which is bounded and cheap. The quorum constant is stated in both
  implementations with a comment naming the other, since one rule living in two languages can only be kept
  honest by saying so. `EdgesFolded` is logged separately from `EdgesPruned` — the fold DELETES rows the
  connection dump would have shown, and a silent removal reads like a silent failure.
- **`metrics/snapshot` is requested twice on first load** (t=131 ms and t=184 ms), 13 KB each. Small, and the
  second caller was not identified — the two user-triggered `loadLatest()` sites are Poll-now, not load.

## Measured but not yet shown (the other half of "nothing vanishes silently")

`/config-fields` carries measured statements about a file that no screen showed. Displaying them is the point
of measuring them; JSON nobody reads is the same as not knowing.

- **DONE** — `shared/config-advisories/`: one component, shown above the form in the TEMPLATE editor (the
  whole-file write, where the harm is worst). Says: the package ships no file at this path (per family), the
  file declares itself generated, and the grammar was never verified — including the third state, "probed and
  the file has no active setting, so its bytes cannot decide".
- **DONE** — all three editors (host template, host Settings, OU policy) now use that one component. The
  machine-written sentence existed in three wordings; the two host editors showed nothing about the path
  verdict or the grammar's provenance, and the OU editor was already FETCHING `/config-fields` and throwing
  that part of the reply away while reading a separate bulk catalog for one of the three statements.
- **DONE** — the index's `withdrawn` list is shown in the Configuration tab's file pane, at the point of the
  absence: "Template X renders this path but is not offered: package Y ships no file at this path".
- `GET /config-generated` now has **no client**. The endpoint stays (both servers, covered by the package
  install test) because a list view annotating dozens of files at once is its real use; the per-file advisory
  replaced its only caller. The service wrapper was deleted rather than left as dead TypeScript.

## Config-model abstentions — what is measured, what is not (2026-08-22)

Every number here comes from a recorded artifact, not from a memory. Re-derive with
`bossman/scripts/record_path_verdicts.py` (no `--write`), `decide_codecs.py` (no `--apply`) and
`find_renderer_gaps.py`.

**Does the claimed path exist** — `configs/config_path_verdicts.json`, **3993** paths measured against the
real `.deb` in three runs (`scripts/verify-registry-paths.sh`; the driver's state is keyed by PACKAGE, so a
new question needs its own `OUT=`).

| | |
|---|---|
| absent | 2751 |
| file | 1216 |
| directory | 26 |
| of the absent: created by a maintainer script | 54 |
| **index bindings withdrawn** — base (host-independent) | **2001 of 3563** |
| withdrawn on **debian** (12 more: the file is EL-only) | 2013 |
| withdrawn on **redhat** (2 more, 1 binding only EL has) | 2002 |
| not downloadable, so NO verdict | 678 Debian + 149 EL packages |

Measured on both distributions, and **20 of 83** overlapping paths DISAGREE: `/etc/named.conf` is absent from
Debian's bind9 (which reads `/etc/bind/named.conf`) and a real file on EL; likewise
`/etc/dovecot/dovecot.conf`, `/etc/hostapd/hostapd.conf`, `/etc/cyrus.conf`. So the verdict lives under
`by_family` — the same shape the codec registry already uses — and the top level is the conservative aggregate:
any family that found a file makes it `file`, because a file that exists somewhere must never be withdrawn in
the host-independent view. The corpus guard yields where the family was measured directly: on a Debian host
`/etc/named.conf` really is not there, so offering Configure would write a file the daemon ignores.

The third run (1069 paths of real config files) withdrew **nothing further** — its paths are registry entries
that were never index-bound. Control cases that must survive and do: `/etc/hostname`, `/etc/passwd`,
`/etc/named.conf`, `/etc/ssh/sshd_config`, `/etc/nginx/nginx.conf`, `/etc/samba/smb.conf`.

THREE guards decide when a verdict may not withdraw, and all are recorded fields rather than judgement:
`exists_elsewhere` (the harvested corpus has real text there — 51 cases, e.g. `/etc/named.conf`, EL-only) and
`configs/config_unowned_paths.json` (the package manager itself disclaims the file in a base image — 34 of
debian:12's 106 `/etc` files, e.g. `/etc/hostname`). Container-only artifacts are recorded with that label and
earn no exemption. The third is `shipped_by`: a verdict answers "does package P contain path X", so when P is
not the package that ships X the answer is true about P and says nothing about X. **72 of 79** non-file
verdicts whose path is in the corpus name the wrong package — `/etc/os-release` was measured in `distrobox`
(it belongs to base-files), `/etc/crontab` in `cronie` (crontabs), `/etc/bind/named.conf` in a puppet module
(bind9). Caught in the browser: the Configuration tab warned "no file here" on `/etc/os-release`. **A third run is in progress** over the 1500 registry paths that still carry no verdict.

**Is the named owner a package at all** — `configs/codec_package_claims.json`, from
`bossman/scripts/audit_package_claims.py`. Found while asking why 678 names could not be downloaded: the list
was full of `LCDd.conf`, `ModemManager.conf`, `Xsession`, `afs.conf`, `config.cfg`. Of **4936** names in the
registry's `packages` fields:

| | |
|---|---|
| known (in `package_universe_real.json`) | 4557 |
| a configuration FILE, not a package (`.conf`/`.cfg`/…) | 213 |
| not a legal package name at all (Debian Policy 5.6.1 — capitals) | 25 |
| unknown — mostly program names (`agetty`, `atd`, `chronyc`, `audit2allow`) | 141 |

238 entries carry at least one such name; **32** would be left with NO owner if those names were simply
removed, which is a worse claim than a wrong one — it cannot even be refuted. So nothing is removed and the
number is on the table instead.

The feared consequence did NOT occur and that is worth stating: the ROLE catalog has **0** such names, so no
role silently fails to be detected as installed. The damage is confined to the codec registry, where it
means those 238 paths cannot be path-verified — which is exactly part of the 263 above.

**Was the grammar tested** — 7287 registry entries claim a codec the write path acts on. 6259 were decided by
round-tripping a real file; the remaining **1028 split into three states that used to read alike**:

| | |
|---|---|
| moot — no file exists at that path (both guards applied) | 684 |
| probed, and the file could not decide: it ships with **no active setting** (`configs/codec_probe_verdicts.json`) | 81 |
| a file exists there and it has not been probed | **0** |
| no evidence either way | 263 |

The last 263 are not a task that can be started as it stands, and the reason is recorded rather than guessed:
**170** name a package `apt-get download` cannot fetch, **86** name no package at all, **13** are glob paths — a glob identifies a SET of files, so "does it exist" is
not a question about it. The middle row is the one worth watching: it says every path where a file demonstrably
exists has already been probed, so this backlog does not shrink by probing harder, only by reaching those 170
packages.

The 81 are a dead end for the round-trip method, not a backlog item: `/etc/security/limits.conf`,
`/etc/sysctl.conf` and 79 others are entirely comments. Their evidence is the **commented** settings —
`activate_commented_settings.py`.

**Directive mining: the file existing is not the same as being minable.** I sized a work list as "223 paths
whose file is measured to exist, therefore immediately minable" and that was too optimistic by an order of
magnitude: **24** were mined, **199** were refused, and the refusals are honest rather than broken. What the
run measured:

| class of the 199 | n | why the miner refuses |
|---|---|---|
| `/etc/default/*` | 68 | shell variables; the man page of the daemon documents flags, not the file |
| other | 82 | mixed; each says "documentation is not about this file (0% of its keys appear)" |
| cron fragments | 25 | a schedule, not settings |
| XDG `.desktop` | 11 | documented by the freedesktop **spec**, not by any man page |
| Apache fragments | 6 | grounded on apache2(8), which documents none of their keys |
| AppArmor profiles | 4 | a policy language |
| X resources (`.ad`) | 3 | an X resource database |

So the constraint is not "has a file" but "has documentation ABOUT this file", and `doc_is_about` is doing
exactly its job — 0% of keys appearing means the page is about something else, and inventing values from it is
the failure this gate exists to prevent. The evidence these classes need is a SPEC (freedesktop, AppArmor,
Xrm) rather than a man page, which is a different source, not a harder prompt.

**111 templates bound to two paths** cannot be resolved from what is recorded, and the attempt is worth writing
down so it is not repeated: none of the 111 has a `target_path` in its `meta.json`, and re-running
`attribute_templates_by_text.py` over the full corpus places **0** of them (196 contested, 4236 with too few
distinctive lines). Several are basename-named dirs bound across unrelated software — `main.conf` to BOTH
`/etc/iwd/main.conf` and `/etc/bluetooth/main.conf` — so this is a NAME COLLISION, not a choice between two
candidates. Picking "the one that exists" would attach a whole-file renderer to a file it may not render,
which is the aardvark-dns damage class. The mechanism that fixes it exists: `qualify_packages._record_target`
now writes `target_path` at generation time; these are legacy dirs from before it, and a batch re-run for their
packages would record the answer instead of guessing it.

**Templates that cannot render** — `configs/template_render_broken.json`, 98 entries. The reasons are
truncated at 400 characters and the parser's diagnosis sits after the echoed body, so use
`TEMPLATE_DIAGNOSE=1 go test ./internal/modules/ -run TemplateDiagnose -v` to read them.

| | |
|---|---|
| individual syntax errors (no class; 2 unclosed comment, 2 invalid numeric token) | 46 |
| of those 52 parse failures, bound in the index and thus reachable by a user | **0** |
| of those 52, whose body is a shell SCRIPT rather than a config (`${#ARRAY[@]}` reads as `#}`) | 4 |
| `template.j2` is **zero bytes** — never generated, not a syntax error | 6 |
| renderer gap (`.get()` — the only method gonja lacks, plus `values`) | 12 |
| renders empty / invalid YAML | 6 |

**Latent renderer gaps** — `configs/template_renderer_gaps.json`: **36** templates, of which **9** are still
offered after the phantom-path withdrawal (`apt-cudf`, `autofs`, `config`, `config.php`, `dnf`, `frr`, `login`,
`luakit`, `mpd.conf`).

This entry said **125** and that was wrong. The method list was written by hand and never tested against the
engine; `internal/modules/gonja_methods_test.go` now asks it, and gonja v1.5.3 executes `items`, `keys`,
`append`, `split`, `join`, `upper`, `strip` and `format` perfectly well. Only **`get`** and **`values`** fail.
Seven wrong entries in a nine-method list turned a real 27 into a reported 125.

Why it is latent even when the sample supplies the value: `{% if x.get('k') is defined %}` does not fail —
`is defined` swallows the error and the guard reads false, so the branch silently never fires. That is also
why a mechanical repair is **abstained** rather than applied: `bossman/scripts/repair_renderer_get.py`
rewrites `x.get('k')` to `x.k | default(…)` correctly, but its safety criterion (output byte-identical) is the
wrong one here — a fixed template legitimately renders MORE than the broken one did, and byte-identity cannot
tell that from damage. All four candidates were reverted by it. `/config-fields` names the gap as
`renderer_gaps` in the meantime.

**Uncalibrated directive catalogs** — 510. "This key is in no documentation" only counts where the page
documents ≥60% of the catalog; below that the page is the weak witness, not the key.

## Package catalog: templates never become roles — DONE 2026-08-23

The cause named below (codec keys are full PATHS, template dirs are package-ish NAMES, intersection 54 of
1982) is gone: the path->template index IS that join, measured from each template's own `meta.json`
`target_path`. What remained was promotion, and promotion needed one more measurement.

`bossman/scripts/promote_index_to_catalog.py --write` promoted **398** entries (catalog 89 -> 487) behind four
measured conditions: bound in the index and not already curated, exactly ONE bound path (two would mean
guessing which is "the" config file), the path measured as a real `file`, and at least one REAL package name
(165 candidates fail this — `packages` sometimes holds a filename).

**`kind` is measured, not defaulted.** Promoting everything as `config` would have bought a single listing
table: the add-roles wizard, the provision wizard and the blueprint palette all skip `config` entries on
purpose. `bossman/scripts/find_package_services.py` extracts each candidate package and reads its systemd
units, so `feature` is claimed only where a unit exists that can actually be enabled:

| | |
|---|---|
| packages measured | 396 |
| ship an enableable unit | 160 |
| ship units, none enableable directly (`apt-daily.service`, `acmetool.service`) | 20 |
| ship no unit at all | 216 |
| **promoted as `feature` with a measured service** | **156** |
| promoted as `config` | 242 |

Never `role`: a role also carries a monitoring check in this vocabulary and nothing here measures a check.
Where several units are enableable and none matches the package name, the service is an ABSTENTION rather than
the first alphabetically — that rule was added after `autosuspend` was given
`autosuspend-detect-suspend.service`.

`category` is empty on derived entries and the UI resolves it from the path (`catalogCategory()`, one reader of
`shared/config-categories.ts`), so the rule does not exist twice. Verified in the browser: the wizard went
from ~75 installable entries in 10 categories to **252 in 21**.

~~Still open here: the new categories render with a generic folder icon…~~ **DONE 2026-08-26** — and both
halves turned out to be worse than recorded.

The icons: **two** wizards each kept their own `CAT_META` of 11 categories while `shared/config-categories.ts`
had 19 with labels and icons, and the lookup it wanted (`categoryByKey`) already existed unused. Both tables
are gone; the catalog's own words (`virtualization` where the shared table says `virt`, plus `monitoring`,
`directory`, `backup`) are met by aliases where they arrive.

The "111 two-path templates" were not *rejected* — they were **bound**, and there were 130 of them. 114 are
one file in several locations (`/etc/magic`, `/etc/apache2/magic`), which is correct. The other 16 were a live
defect of the worst class: the codec entry keyed `apparmor.d` lists **259** paths, so `/etc/apparmor.d/Discord`
offered to render a generic profile skeleton over Discord's profile; `logrotate.conf` did it to 20 fragments
and `apt.conf` to 17. And the same damage assembled across sources — the catalog binds `nginx` to
`/etc/nginx/nginx.conf` while the codec registry also bound it to `/etc/logrotate.d/nginx`.

**One template renders one file** is now a rule in `template_index`, the mirror image of the conflict rule
that has always reported two templates for one path. 341 bindings withdrawn with a stated reason, 0 templates
left bound to differently-named files, and the paths a surface offers went 1538 → 1226.

## Original finding (2026-07-28, via "und was ist mit LDAP?")

- **The bottleneck is name matching, not template generation.** `scripts/build_package_catalog.py`
  is codec-driven: a config file in the codec registry that *has* a template becomes a catalog
  entry. But codec keys are **full paths** (`/etc/default/slapd`) while template directories are
  **package-ish names** (`slapd`, `389-ds`). Measured: **1982 template dirs, 1553 codec keys,
  intersection 54** → `package_catalog.json` has **38** entries (24 `kind: role` + 14
  `kind: config`). So ~1900 generated templates are invisible to the catalog and never become a
  role/wizard. This — not the qualify batch's progress — is why "we only have 38 roles" while
  `package_universe_real.json` lists debian 8555 / ubuntu 9112. Fixing the mapping (derive a
  basename/package key on both sides) is the single biggest unlock; caveat: auto-derived entries
  carry no label/service/families, so they'd be weaker roles than the curated CORE table's.
- **No LDAP *server* role exists.** Only `ldap.conf` is in the catalog, correctly as
  `kind: config` — it is `/etc/ldap/ldap.conf`, the OpenLDAP **client** config. Templates for the
  server side do exist on disk but were never promoted: `slapd` (6 fields — only
  `/etc/default/slapd`, i.e. startup options), `389-ds` (6 — systemd instance),
  `389_directory_server` (34 — LDIF, whose own generated header says *"Do NOT edit directly; use
  the dsconfig CLI or LDAP operations instead"*).
- **Why LDAP is the hardest case, and what it teaches:** both OpenLDAP (`slapd.d` / `cn=config`)
  and 389-ds (`dse.ldif`) keep their configuration in an **LDIF database the daemon owns**, not in
  a text file. A config template + codec is the wrong mechanism there; such servers are configured
  through `ldapmodify` / `dsconf`, i.e. **runbook steps**. Generalising: the template/codec pipeline
  only fits packages whose config IS a flat file — packages with a daemon-owned config store need a
  role with steps instead. Worth a `kind` beyond `role|config` to mark them.
- Adding LDAP by hand would mean a curated CORE entry (label, a new `identity` category — the
  catalog has none today, though the Management tab does have an Identity group with the FreeIPA
  snap-in — families debian `slapd`+`ldap-utils`, service `slapd`) plus a matching palette
  component in the blueprint editor.
