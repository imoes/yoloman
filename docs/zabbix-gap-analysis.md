# Zabbix 7.0 feature gap analysis

Systematic, chapter-by-chapter comparison of the [Zabbix 7.0 manual](https://www.zabbix.com/documentation/7.0/en/manual)
against yolo-man, read word for word. Process: read a chapter batch → extract every distinct
feature → check it against the real codebase (file:line, not memory) → present the gaps →
user decides (implement now / defer / reject) → record the decision here → commit.

Status legend: ✅ implemented · 🟡 partial · ❌ missing · ⏭ out of scope (decided)

Out-of-scope chapters (confirmed with user, 2026-07-07): Ch.1 Introduction, Ch.2 Definitions,
Ch.4 Installation and First Steps, Ch.5 Quickstart Guides, Ch.6 Zabbix Appliance, Zabbix Cloud,
Developer Center, Zabbix Manpages, Copyright Notice — Zabbix's own install/ops mechanics, not
comparable user-facing features.

## Progress

- [x] Batch 1 — Ch.3 Zabbix Processes (light) — 3 gaps found; HA deferred, Housekeeping (K1) + Runtime control (K2) implemented
- [x] Batch 2 — Ch.7a Configuration: Hosts/groups, Items — 18 gaps found; K1-fix+K1b+K2b+K2c+K4+K5 implemented, K3 planned (deferred)
- [x] Batch 3 — Ch.7b Configuration: Triggers, Events, Event correlation, Tagging — 6 gaps found; K6+K7+K8+K9+K10 implemented, event correlation deferred
- [x] Batch 4 — Ch.7c Configuration: Visualization, Templates — 3 gaps found, decisions below
- [x] Batch 5 — Ch.7d Configuration: Notifications, Macros — 13 gaps found; recommendations below (incl. a real dispatch bug K13-fix); no code yet, awaiting decisions
- [x] Batch 6 — Ch.7e Configuration: Users/permissions, Secrets, Scheduled reports, Data export — 12 gaps found; two real security defects flagged (K14-fix RBAC not enforced, K15-fix plaintext agent tokens); no code yet, awaiting decisions
- [x] Batch 7 — Ch.8 Service Monitoring + Ch.9 Web Monitoring + Ch.10 VM Monitoring — 9 gaps found; one correctness fix flagged (K16-fix downtime not excluded from availability); no code yet, awaiting decisions
- [ ] Batch 8 — Ch.11 Maintenance + Ch.12 Regexp + Ch.13 Ack + Ch.14 Config Export/Import
- [ ] Batch 9 — Ch.15 Discovery
- [ ] Batch 10 — Ch.16 Distributed Monitoring (Proxies) + Ch.17 Encryption
- [ ] Batch 11 — Ch.18a Web Interface: Dashboards + widgets
- [ ] Batch 12 — Ch.18b Web Interface: Monitoring/Services/Inventory/Reports
- [ ] Batch 13 — Ch.18c Web Interface: Data collection/Alerts/Users/Administration
- [ ] Batch 14 — Ch.19 Best Practices + Ch.20 API + Ch.21 Extensions + Ch.22 Appendixes

## Baseline inventory (verified 2026-07-07, before the chapter-by-chapter read)

Seeded by two code-reading agents that inventoried the current codebase against Zabbix's core
concepts, so the gap analysis starts from verified ground truth. Every line is file:line-cited.
This will be folded into the per-chapter sections below as each chapter is actually read; kept
here as the starting reference.

### Bossman backend (Python)

| # | Concept | Status | Note |
|---|---|---|---|
| 1 | Hosts/host groups | 🟡 | flat `Agent.groups: list[str]` (db/models.py:94), no nesting, no tags, inventory = one unstructured `facts` JSONB blob |
| 2 | Items | 🟡 | `Metric` generic time-series (db/models.py:215-229), pull-only (poller.py:277-349); no trapper/calculated/aggregate/dependent items, no preprocessing pipeline |
| 3 | Triggers | 🟡 | `CheckRule` single-metric threshold (db/models.py:320-370) + host>group>global precedence + soft/hard+flapping (monitoring.py:43-176); no multi-item boolean expressions, no trigger-to-trigger dependencies |
| 4 | Events + correlation | ❌ | `ServiceStateHistory` exists but no correlation engine (grep-verified, zero hits) |
| 5 | Tagging | ❌ | no structured tag system anywhere |
| 6 | Templates | ❌ | weak analog only: `CheckRule.scope_type="group"` propagates one rule to a group; `seed_default_check_rules` is a fixed 2-rule seed, not an editable template catalog |
| 7 | Notifications (media/actions/escalation) | 🟡 | `NotificationRule` flat, `channel` restricted to email\|webhook (db/models.py:436-458), single flat AND condition, **no escalation** (no multi-step/time-delayed); full CRUD exists (api/notifications.py) |
| 8 | Macros | 🟡 | genuine host_vars-style plan-param templating (plan_loader.py:405-416) but not for thresholds/notification messages; no secret macros |
| 9 | Users/roles/tokens/auth | 🟡 | `role` column exists (db/models.py:232-243) but **never enforced anywhere** (grep-verified) — no real RBAC; `ApiToken` has no scopes; no LDAP/SAML/MFA |
| 10 | Secrets storage | ❌ | plain env vars (config.py); mTLS private key is just a chmod-0600 file (keys.py:53-61) |
| 11 | Scheduled reports | ❌ | none |
| 12 | Data export (bulk/streaming) | ❌ | none beyond the per-event notification webhook |
| 13 | IT Services/SLA tree | 🟡 | real flat per-service SLA (`compute_availability`, monitoring.py:521-584, Block H9) but no service-tree/business-service rollup |
| 14 | Maintenance windows | 🟡 | `Downtime` single fixed window per single agent (db/models.py:484-500); no recurrence, no group/tag scoping |
| 15 | Ack + suppression | ✅ | timed ack with auto-expiry (monitoring.py:634-672, Block H5), flapping/downtime suppression at notify time; missing: no distinct "suppressed" state, no bulk-ack |
| 16 | Config export/import | ❌ | none for check_rules/notification_rules/downtimes |
| 17 | Discovery | 🟡 | active-agent autoregistration ✅ (enroll.py/enrollment.py), satellite auto-discovery via proxy ✅ (poller.py:176-257); no network-subnet scan; LLD hardcoded to disk-mount fan-out only |
| 18 | Distributed monitoring/proxies | 🟡 | proxy/satellite relay works (`Agent.mode`+`parent_agent_id`); no proxy HA/load-balancing/richer sync protocol |
| 19 | Encryption | ✅ | mTLS only, own keypair+cert (keys.py:25-76); no PSK mode, no key rotation |
| 20 | Audit log | 🟡 | no generic config-change audit log; only `PlanRun` and `Notification` exist as domain-specific trails |
| 21 | Housekeeping | 🟡 | retention hardcoded in Alembic migrations (14/30/30 days), not configurable, no UI/API |
| 22 | Queue/value-cache backlog | ❌ | none |
| 23 | API completeness | 🟡 | check-rules/notification-rules full CRUD; downtimes missing update; agents no create/delete via REST; plans read-only+run; single flat undifferentiated auth |

### UI (Angular) + Agent (Go)

| # | Concept | Status | Note |
|---|---|---|---|
| 24 | Dashboards+widgets | 🟡 | real GridStack dashboard (dashboard-grid.component.ts) but only 6 widget types vs Zabbix's ~30 |
| 25 | Problems view | 🟡 | state+host+ack filters only; no tags, no time-range, no sort, no dedicated suppressed filter |
| 26 | Hosts/Latest data | ✅ | deep (CheckMK-style service list + SLA bar + grouped latest-data + gauges/charts); no value-mapping display |
| 27 | Maps/Topology | 🟡 | auto-layout graph from real eBPF edges + synthetic proxy links; no manual map editor/persisted layout/link-indicator rules |
| 28 | Discovery UI | ❌ | no fleet-wide pending/discovered-hosts view |
| 29 | Services/SLA UI | 🟡 | SLA bar exists per-service on the host page only; no top-level Services route/service-tree |
| 30 | Inventory | 🟡 | deep auto-detected HW/SW facts per host; no manual asset fields, no cross-host overview screen |
| 31 | Reports | ❌ | no scheduled reports/fleet availability report/top-100/audit-log viewer; notifications page is a send-log only |
| 32 | Alerts UI (actions/media/scripts) | 🟡 | one flat rule form; no condition trees/escalation steps/script operation/media-type admin screen |
| 33 | Users UI | ❌ | backend ACL primitives exist (internal/authz/acl.go), no Angular UI calls them |
| 34 | Administration/settings | 🟡 | session/enrollment/plan-reload/check-rules/host-groups only; no general-settings/audit-log/housekeeping/proxy-mgmt/macros/queue UI |
| 35 | Modules UI | ✅ | implemented, different concept (module/collection registry, not item+trigger template bundling) |
| 36 | Item types (agent) | 🟡 | `/proc` collectors + Nagios-plugin checks + tools.d tasks + eBPF; no SNMP/IPMI/JMX/DB-monitor; `uri.go` is one-shot HTTP, not a scheduled HTTP-agent type |
| 37 | Web monitoring/browser items | ❌ | no multi-step scenario/login-flow checks |
| 38 | Preprocessing | ❌ | no JSONPath/regex/JS/unit-conversion pipeline on raw values |
| 39 | Value mapping | ❌ | not a configurable feature |
| 40 | Low-level discovery (agent-side) | 🟡 | disk-mount fan-out is the only instance; NICs enumerated for inventory/metrics but never generate per-NIC checks |
| 41 | Encryption (agent-side) | 🟡 | mTLS only, own pinned-key model (tlsauth.go); no PSK mode |
| 42 | Active vs passive checks | 🟡 | pull/passive only; no trapper/sender-equivalent push endpoint |
| 43 | High availability | ❌ | single-instance, no HA/failover anywhere |
| 44 | eBPF observability | ✅ | differentiator — Zabbix has no equivalent (exec events, TCP tracking, disk I/O latency, Block J1's process list) |

---

## Batch 1 — Ch.3 Zabbix Processes

Read: [manual/concepts](https://www.zabbix.com/documentation/7.0/en/manual/concepts) (overview) +
[manual/concepts/server](https://www.zabbix.com/documentation/7.0/en/manual/concepts/server) (full detail incl. High Availability + runtime control).

Server = "the central process that performs polling and trapping of data, calculates triggers, and
sends notifications to users." Its internal process-thread breakdown (agent/SNMP/HTTP/ICMP/IPMI/
Java/ODBC pollers, history syncer, preprocessing manager/worker, trapper, alert manager/alerter/
escalator, task manager, configuration syncer, discovery/LLD manager+worker, housekeeper, self-
monitoring, connector manager/worker, report manager/writer, proxy group manager, timer, web
monitoring) is Zabbix's own internal architecture, not a checklist of separate user-facing
features — most of it maps to concepts already tracked in the baseline (item types #36, discovery
#17/#40, data export #12, scheduled reports #11, web monitoring #37) and got full treatment when
those chapters were read (Ch.7, Ch.9, Ch.15). Three items were new or meaningfully sharpened an
existing baseline entry:

| Feature (Zabbix) | Detail | yolo-man status | Note |
|---|---|---|---|
| High Availability (server) | Multiple server nodes, active/standby, database-coordinated failover, configurable failover delay (min. 10s, `ha_set_failover_delay`), node registration/removal (`ha_status`, `ha_remove_node`) | ❌ missing (sharpens baseline #43) | Bossman is single-instance; no multi-node coordination, no failover of any kind. A Bossman crash/restart is a monitoring outage until it comes back. |
| Housekeeping (as a live, configurable, triggerable process) | Per-data-type retention, `housekeeper_execute`/`trigger_housekeeper_execute` runtime-triggerable without restart | 🟡 sharpens baseline #21 | yolo-man's retention (14/30/30 days) was hardcoded in Alembic migrations — not configurable, not manually triggerable, no per-table breakdown of what's being cleaned. |
| Runtime operational control plane | Live cache reload, log-level increase/decrease, diagnostics dump (`diaginfo`), profiling toggle, secrets reload — all without restarting the process | ❌ missing (new) | Bossman had no equivalent: no live log-level control, no diagnostics/queue-depth dump endpoint, no way to force a reload of anything short of a full redeploy. |

**Decisions (user, 2026-07-07):**
- High Availability → **defer** (roadmap; genuine multi-node HA is a large, standalone block, sensible after the rest of this analysis lands)
- Configurable/triggerable housekeeping → **implement now** → **K1, done**
- Runtime operational control plane (diagnostics + live log-level) → **implement now** → **K2, done**

---

## Batch 2 — Ch.7a Configuration: Hosts/host groups, Items

Read: [config/hosts](https://www.zabbix.com/documentation/7.0/en/manual/config/hosts),
[config/hosts/host](https://www.zabbix.com/documentation/7.0/en/manual/config/hosts/host) (full host form),
[config/hosts/host_groups](https://www.zabbix.com/documentation/7.0/en/manual/config/hosts/host_groups),
[config/hosts/hostupdate](https://www.zabbix.com/documentation/7.0/en/manual/config/hosts/hostupdate) (mass update),
[config/hosts/inventory](https://www.zabbix.com/documentation/7.0/en/manual/config/hosts/inventory),
[config/items/itemtypes](https://www.zabbix.com/documentation/7.0/en/manual/config/items/itemtypes) (all 20 item types),
[config/items/preprocessing](https://www.zabbix.com/documentation/7.0/en/manual/config/items/preprocessing) (all ~30 preprocessing steps).

| Feature (Zabbix) | Detail | yolo-man status | Disposition |
|---|---|---|---|
| Host groups: nested/hierarchical | `Europe/Latvia/Riga` slash-notation subgroups; permissions inherit to children; tag filters apply recursively | ❌ sharpens #1 (flat `groups: list[str]` only) | **implement now** |
| Host groups: permission scoping | "All permissions are based on groups: user groups, host groups, template groups" — a user group's access is granted per host group | ❌ sharpens #1/#9 (no RBAC enforced at all) | **defer** (bundled with real RBAC, a bigger future block) |
| Host inventory: manual fields + auto-population routing | 3 modes (disabled/manual/automatic); in automatic mode, *any* item can be flagged "populates host inventory field X" | 🟡 sharpens #1/#30 (facts are auto-collected but fixed/hardcoded, no manual entry, no per-item routing) | **defer** |
| Multiple interfaces per host (agent/SNMP/JMX/IPMI, distinct ports, one marked default) | e.g. a host can be polled via Zabbix agent on 10050 *and* SNMP on 161 simultaneously | ❌ sharpens #36 (one address per Agent row) | **defer** (low value until a non-agent item type exists) |
| Encryption: per-direction config + cert issuer/subject restriction + PSK | Separate "connections to host" vs "connections from host"; PSK mode (hex key, no cert infra needed) | 🟡 sharpens #19/#41 (mTLS only, no PSK, no direction split) | **defer** (mTLS already meets the actual security goal) |
| Mass update (bulk-edit groups/templates/macros/tags/inventory/encryption across many selected hosts at once) | One form, checkbox-per-attribute, applies to a multi-select | ❌ new, not in baseline | **implement now** |
| Item types: SNMP/IPMI/JMX/Database-monitor/SSH/Telnet/Prometheus-check | Protocol-specific pollers on the server side | ❌ sharpens #36 | **reject for now** — no host in this fleet needs SNMP/IPMI/JMX/DB-monitor/SSH-as-a-check today; revisit if a concrete host requires one (e.g. a network switch) |
| HTTP-agent item type (scheduled URL poll as a first-class recurring item, response parsed/stored) | Distinct from Ch.9's multi-step web *scenarios* — this is a single recurring check | 🟡 sharpens #36 (`uri.go` is one-shot, not a scheduled item) | **defer** |
| Calculated items + Aggregate calculations (derive a value from other items' data via a formula, e.g. avg of a host group's CPU) | No separate poll — computed from already-collected data | ❌ sharpens #2 | **defer** (valuable — "smarter thresholds" — but a real design effort) |
| Dependent items (a "sub-item" that's just preprocessing applied to a master item's raw value, no separate poll) | E.g. one big JSON poll → many dependent items each extracting one field | ❌ sharpens #2/#38 | **defer** (depends on preprocessing existing first) |
| Item preprocessing pipeline — ~30 chainable, testable-before-save transform steps (regex/JSONPath/JS/unit-conversion/validation/etc.) | Chained in order, each step testable independently before saving | ❌ missing entirely (baseline #38) | **defer**, replaced by a narrower, concrete need surfaced in discussion — see "K3 (planned)" below |
| Value mapping (numeric/string → human label, e.g. 0→"Down") | Reusable named value-map objects, attached to any item | ❌ (baseline #39) | **implement now** → K4 |
| History + Trends (two-tier storage: raw history for N days, then hourly min/avg/max "trends" retained far longer/indefinitely) | Trends survive after raw history is housekept away — long-term graphs stay meaningful | ❌ **corrected finding** (see below) | **implement now** → **K1b, done** |
| "Execute now" (force one item to be checked immediately from the UI, bypassing its interval) | One-click on-demand recheck | ❌ new, small | **implement now** → K5 |
| User parameters (admin-defined custom check keys on the agent, no recompiling) | `UserParameter=mykey,command` in agent config | 🟡 already covered differently — tools.d YAML tasks + Nagios-style checks serve the same "add a custom check without recompiling" need | no action |
| Windows performance counters | Windows-specific | ⏭ out of scope | **reject** — yolo-man is Linux-fleet-focused (per CLAUDE.md's Proxmox/Linux context) |
| Queue (which items are overdue/late, per-item) + Value cache (in-memory history-read cache, tunable) | Frontend diagnostic views | 🟡 sharpens #22; K2's diagnostics (Block K2, this session) already gives a coarse poller-lag view | **defer** — deeper per-item queue view is low priority at current fleet size |
| Restricting agent checks (agent-side allow-list of which item keys the server may invoke) | Security hardening on the agent side | 🟡 roughly covered — internal/authz's write-gate/ACL already restricts what a caller can invoke | no action |

**Decisions (user, 2026-07-07) + a correction found while implementing:**

- **Item preprocessing pipeline → deferred**, but not for lack of interest — a real discussion
  surfaced a narrower, concrete need instead: yolo-man's check-output model is deliberately
  Nagios/CheckMK-plugin compatible today (exit code + stdout → OK/WARN/CRIT/UNKNOWN, see
  `internal/checks/checks.go`), which is exactly why the full ~30-step Zabbix transform pipeline
  has nothing to act on yet — none of yolo-man's item types return the kind of messy raw
  SNMP/HTTP/script output Zabbix's preprocessing exists to clean up (and the item types that
  would, were rejected/deferred above). What's wanted instead: **(a)** a parser for check-output
  formats *beyond* Nagios/CheckMK's, **(b)** less strict state evaluation (not force everything
  through a rigid exit-code mapping), **(c)** exposing the full structured check output as JSON
  over the API instead of flattening it to a single value+state. Logged as **K3 (planned)** — a
  properly scoped design task, not started this batch.
- **History + Trends → implemented (K1b), with a correction to the question itself.** The initial
  framing ("build a trends system from scratch") was wrong: a real check of the codebase (prompted
  by the user's own skepticism) found the Go agent's local SQLite store **already** does
  raw→hourly→daily downsampling (`internal/store/sqlite.go`'s `Downsample`/`consolidate`), and
  Bossman's own initial schema **already** has a `metrics_hourly` TimescaleDB continuous aggregate
  (`alembic/versions/f17d664762b0`) — but it was never queried by any code path, and had no
  retention policy of its own. The actual, much smaller gap: raw `metrics` are deleted after 14
  days (TimescaleDB-native `add_retention_policy`, confirmed as a real registered background job)
  with the hourly rollup sitting unused. Implemented: `metrics_daily` continuous aggregate (new
  migration `cd09bed433e7`) + explicit retention (hourly 90d, daily 365d, matching the "365 days,
  CheckMK-RRD-style" spec already in docs/plan.md's original Node Agent design) + a tiered
  read-path (`services/metrics_query.py`) that transparently serves raw/hourly/daily depending on
  how far back a query reaches. Verified against real, registered TimescaleDB jobs (not just that
  the migration ran) — see the K1b commit for the `psql` output.
- **This also caught a real bug in K1 (this session's own earlier work):** the original
  housekeeping implementation redundantly re-deleted rows from `metrics`/`connection_events`/
  `service_state_history` in Python — tables that **already** had native TimescaleDB retention
  policies since the initial schema. Changing `settings.metrics_retention_days` would have had
  **no actual effect** (the DB-native policy would still win), a latent correctness bug. Fixed:
  `run_housekeeping` is now scoped to `notifications`/`plan_runs` only (the two tables that
  genuinely had no retention at all); the three hypertable settings remain as informational
  mirrors of the real DB-level policy, now given a real second purpose as the tier-selection
  thresholds for K1b's read path.
- **Host groups: nested + Mass update → both implemented now** (K2b/K2c, see below).
- **Value mapping + "Execute now" → both implemented now** (K4/K5, see below — small, high
  day-to-day value as the user judged).

---

## Batch 3 — Ch.7b Configuration: Triggers, Events, Event correlation, Tagging

Read: [config/triggers/expression](https://www.zabbix.com/documentation/7.0/en/manual/config/triggers/expression),
[config/event_correlation](https://www.zabbix.com/documentation/7.0/en/manual/config/event_correlation) +
[config/event_correlation/global](https://www.zabbix.com/documentation/7.0/en/manual/config/event_correlation/global),
[config/tagging](https://www.zabbix.com/documentation/7.0/en/manual/config/tagging).

| Feature (Zabbix) | Detail | yolo-man status | Disposition |
|---|---|---|---|
| Multi-item/multi-host boolean trigger expressions | `function(/host1/key1,param) or function(/host2/key2,param)` — AND/OR/NOT across different hosts/items in one trigger | ❌ sharpens #3 (`CheckRule` is single-metric, single-comparison only) | **implement now** → K9 (scoped to same-host; cross-host correlation still out of scope) |
| Trigger dependencies (one trigger suppresses another's notifications — root-cause vs symptom) | Prevents alert fatigue: a "disk full" problem suppresses a dependent "backup job failed" symptom alert | ❌ sharpens #3/#4 | **implement now** → K8 |
| Recovery expression (a separate condition for when a problem resolves, distinct from the problem condition — hysteresis) | Without one: resolves when the problem expression goes false. With one: resolves only when problem=false AND recovery=true | 🟡 partial equivalent — `next_transition`'s hard/soft state machine (Block H7) already prevents flapping via `max_attempts`, but there's no separate, independently-configurable recovery threshold (e.g. warn at 80%, only recover below 70% — a deadband) | **implement now** → K6 |
| Custom trigger severity names/colors | Rename/recolor the 6 built-in severities per-installation | ❌ new, small | **implement now** → K10 (display-only rename/recolor; the real state machine stays yolo-man's 4 values, narrower than Zabbix's free-text severities) |
| Event correlation (trigger-based + global rules: match on old/new event tags or tag-value pairs, operations = close old event / close new event) | Worked example: correlate by matching `host`+`port` tag pairs between old and new events, close the new (duplicate) one | ❌ missing entirely (sharpens #4) | **defer** (depends on tagging existing first — see next row) |
| Tagging (host/trigger/item/service tags, `name` or `name:value`, inherited down the whole entity chain into problems, used for filtering/routing/permission-scoping/correlation) | A foundational primitive several other gaps (event correlation, notification routing, RBAC scoping) build on | ❌ missing entirely (sharpens #5) | **implement now** → K7 (foundational — unblocks event correlation and finer notification routing later) |

**Decisions (user, 2026-07-07) — all five "implement now":**

- **Recovery expression / hysteresis → K6, done.** `CheckRule.recovery_threshold`; a problem holds at its
  current state until the value clears this stricter threshold instead of recovering the moment it dips
  under warn_threshold.
- **Tagging → K7, done.** `Agent.tags`, `GET /problems?tag=`, `NotificationRule.tag_filter` — host-level only
  for v1 (event correlation, which needs old/new-event tag matching, stays deferred).
- **Trigger dependencies → K8, done.** `CheckRule.depends_on_service_name`; a symptom's notification is
  suppressed while its named root-cause service (same agent) is a confirmed hard problem.
- **Multi-item boolean trigger expressions → K9, done (scoped).** `CheckRule.extra_conditions` +
  `condition_logic` (AND/OR) combine the primary metric with other same-host metrics —
  e.g. "CPU > 80 AND load1 > 4". Cross-host correlation (Zabbix's fuller multi-host expressions) is a
  materially bigger step, still out of scope.
- **Custom severity names/colors → K10, done (display-only).** New `severity_labels` table,
  `GET`/`PUT /api/v1/severity-labels/{state}` — cosmetic rename/recolor; the real state machine stays
  yolo-man's 4 values (OK/WARN/CRIT/UNKNOWN), narrower than Zabbix's fully free-text severities.
- **Event correlation → deferred**, pending a concrete need (it builds directly on K7's tagging, which is
  now available if this is revisited).

---

## Batch 4 — Ch.7c Configuration: Visualization, Templates

Read: [config/visualization/graphs/custom](https://www.zabbix.com/documentation/7.0/en/manual/config/visualization/graphs/custom),
[config/visualization/maps/map](https://www.zabbix.com/documentation/7.0/en/manual/config/visualization/maps/map),
[config/templates_out_of_the_box](https://www.zabbix.com/documentation/7.0/en/manual/config/templates_out_of_the_box).

| Feature (Zabbix) | Detail | yolo-man status | Disposition |
|---|---|---|---|
| Custom multi-host/multi-item graphs | Combine items from several hosts on one saved chart; per-item color/draw-style(line/bold/filled/dot/dashed/gradient)/Y-axis-side/function(avg/min/max/last/all); graph-level Y-axis mode, percentile lines, legend, working-time overlay, trigger-line overlay, normal/stacked/pie/exploded | ❌ sharpens #24 (dashboard has a `timeseries` widget, but no saved, reusable, cross-host custom-graph builder) | **implement now** (user overrode my "defer" recommendation) → K11 |
| Network maps: manual layout + link indicators + navigation tree | Drag-and-drop element positioning (host/host-group/trigger/map/image elements), link-indicator rules (color/style by linked trigger state), hierarchical map-of-maps navigation | 🟡 sharpens #27 (auto-layout only; no manual editor, no persisted positions, no link-indicator rules) | **implement now** (user overrode my "defer" recommendation) → not yet started |
| **Templates** — a named, reusable bundle of items+triggers+graphs+discovery-rules+dashboards+web-scenarios, **live-linked** (not copied) to a host/group so editing the template cascades to every linked host; nestable (a template links other templates); grouped (template groups); Zabbix ships an out-of-box library for common software (MySQL/PostgreSQL/Docker/network devices/...) | The biggest single gap this analysis has found — genuinely missing (baseline #6); the closest analog, `CheckRule.scope_type="group"`, is one rule at a time, not a bundle, and isn't itself a versioned/nameable object | ❌ missing entirely | **implement now, full scope** (user overrode my recommended "scoped v1") → K12 |

**Decisions (user, 2026-07-07) — all three "implement now":**

- **Custom multi-host graphs → K11, done.** `Graph`/`GraphItem` models (`bossman/alembic/versions/5e81d459a395_custom_graphs.py`),
  `bossman/bossman/api/graphs.py` — named, saved graphs combining metrics from any agents/services, reusing
  `services/metrics_query.query_series` per item for `GET /graphs/{id}/data`. No draw-style/Y-axis-side/percentile
  options (Zabbix's full per-item styling) — a plain multi-series line overlay, not the richer rendering options.
  Found and fixed a real `sqlalchemy.exc.MissingGreenlet` bug along the way: `list_graphs`/`get_graph` were
  touching the lazy `Graph.items` relationship outside an eager-load; fixed with a module-level
  `selectinload(Graph.items)` applied to every query that reaches `GraphOut.from_model()`.
- **Templates → K12, done, full scope.** `Template`/`TemplateRule`/`TemplateGroup`/`TemplateNesting`/`TemplateLink`
  models (`bossman/alembic/versions/ee733489430c_templates.py`), `bossman/bossman/services/templates.py`
  (recursive, cycle-safe effective-rule collection + ancestor-cascade materialization),
  `bossman/bossman/api/templates.py` (full CRUD + link/unlink). A template is a named, editable bundle of
  `TemplateRule` rows; linking it to a host group **live-materializes** real `CheckRule` rows (upserted by
  `source_template_rule_id`, not copied once) — editing the template or its nesting re-materializes every
  linked group and every ancestor template's links too. Templates can nest other templates (self-nesting and
  cycles rejected at the API layer). A materialized `CheckRule` cannot be edited/deleted directly
  (`check_rules.template_id` set → 409, pointing the caller at the template instead). Scope note: Zabbix
  templates also bundle graphs/discovery-rules/dashboards/web-scenarios — this only covers the trigger/item
  (`CheckRule`) side, which is what has real user-facing value here; no out-of-box template library was built
  (no Docker/MySQL/etc. starter templates), since yolo-man's own default checks (`seed_default_check_rules`)
  already cover the equivalent ground.
  - Two bugs found and fixed while testing: (1) `create_template`'s early `session.flush()` (needed to get
    `template.id` before constructing `TemplateRule`/`TemplateNesting` rows) sat outside the `try/except
    IntegrityError` block, so a duplicate template name crashed with a raw `asyncpg.UniqueViolationError`
    instead of a 409 — fixed by having `Template` generate its own client-side UUID so no early flush is
    needed. (2) A test asserted a materialized `CheckRule`'s `.id` stays stable across a template edit; it
    doesn't (whole-form template edits delete+recreate `TemplateRule` rows with fresh UUIDs, so
    materialization treats it as delete-old+create-new by design) — fixed the test to re-query by
    `(template_id, scope_value)` instead of refreshing a stale reference.
- **Manual network maps → accepted, not yet implemented.** Queued as the next piece of this batch's work
  (drag-and-drop layout + link-indicator rules + map-of-maps navigation, building on the existing
  auto-layout topology graph, baseline #27).

## Batch 5 — Ch.7d Configuration: Notifications, Macros

Read: [config/notifications/media](https://www.zabbix.com/documentation/7.0/en/manual/config/notifications/media),
[config/notifications/action/operation](https://www.zabbix.com/documentation/7.0/en/manual/config/notifications/action/operation),
[config/macros/user_macros](https://www.zabbix.com/documentation/7.0/en/manual/config/macros/user_macros).

Bossman side verified against the code (file:line), not memory: model `NotificationRule`
(`bossman/bossman/db/models.py:1030-1063`), CRUD `api/notifications.py`, send path
`services/notification.py`. Today's model is a single fire-once rule with an `email`|`webhook`
channel to one `target`, gated by event type / severity floor / host+service substring / tag subset,
with hard-coded ack/downtime/flapping/dependency suppression at dispatch and a hard-coded message
body. No macro system exists anywhere in the repo.

| Feature (Zabbix) | Detail | yolo-man status | Disposition (recommendation) |
|---|---|---|---|
| Media type: **custom alert script** | Run an arbitrary executable with the message as args/stdin — the universal escape hatch (Slack/Telegram/PagerDuty/Opsgenie all shipped as scripts) | ❌ only `email`+`webhook` channels exist (`notification.py:158-161`) | **implement** — one `script` channel (write-gated exec of a configured command) covers every third-party target for free |
| Media type: **SMS** | Serial-modem / gateway SMS | ❌ missing | **reject for now** — no SMS gateway in this environment; a webhook to an SMS-API covers the rare case |
| Media type retry/concurrency options | Retry attempts (1–100, default 3), retry interval (0–3600s), concurrent-session cap | ❌ a failed send is logged `status="failed"` and never retried (`notification.py:162-163`) | **implement** — small, high-value: a transient webhook/SMTP failure should retry with backoff before giving up |
| **Message templates** — editable subject+body per media type / per event type | 255-char subject + body with macros, defaults per event type (problem/recovery/…) | ❌ body is a fixed f-string (`render`, `notification.py:81-92`); no configurable message field in the model or API | **implement** — a per-rule (or per-channel) subject/body template; pairs with built-in macros below |
| **User macros** `{$MACRO}` with host>template>global override hierarchy, contexts `{$MACRO:context}` incl. regex | Config-time substitution in item keys, trigger expressions, notification text, many fields | ❌ no macro system at all (grep across Python+Go empty; `internal/modules/template.go:20-21` is a reduced Jinja subset that explicitly excludes macros) | **defer** — big, and only pays off once there's a template/host var layer to hang it on; the monitoring `Template` layer (K12) is the natural host |
| **Built-in macros** `{HOST.NAME}`/`{ITEM.VALUE}`/`{TRIGGER.STATUS}`/`{EVENT.*}` in messages | Auto-resolved at send time from the event context | ❌ not implemented (the body only interpolates hard-coded host/service/state fields) | **implement** — the minimum useful set (`{HOST.NAME}`, `{SERVICE.NAME}`, `{ITEM.VALUE}`, `{EVENT.SEVERITY}`, `{EVENT.TIME}`) so the message-template feature above is actually worth having |
| **Secret / vault macros** | Masked value; HashiCorp/CyberArk vault reference | ❌ missing | **defer** — bundle with real secrets storage (baseline #10, still plain env vars) |
| Macro **contexts + macro functions** | `{$MACRO:context}`, regex contexts, value-transform functions | ❌ missing | **reject for now** — niche; revisit only if user macros land and demand it |
| **Actions: escalations / multi-step** | Step ranges (from/to), per-step duration, escalate to a *different* user group at later steps | ❌ fire-once; no step model (`dispatch` sends exactly one attempt per rule per event) | **defer** — real value but a sizeable state-machine + scheduler; scope carefully later |
| **Repeat / renotify until ack or resolve** | Re-send every N minutes while the problem stays unacked | ❌ missing (one-shot) | **implement (scoped v1)** — a per-rule "renotify every N min until acknowledged/recovered" is the 80% of escalation value without the multi-step machinery |
| **Recovery + update(ack) operations** | Distinct notification when a problem recovers / is updated / acknowledged | 🟡 `on_recovery` exists (`models.py:1041`); no notify-on-ack / notify-on-update | **defer** — low marginal value until escalation exists |
| Action condition: **time period / active window** | "only send 00:00–06:00" per action, user-timezone aware | ❌ no time-window column or check anywhere | **implement** — common real need ("only page at night"); a per-rule active-window string like the downtime windows already parsed |
| Action condition: **host group** (not just substring) | Condition on structured host-group membership incl. nested groups | 🟡 only `host_filter`/`service_filter` substrings + `tag_filter` (`notification.py:60-78`); no group-membership condition | **implement (small)** — reuse the nested-group match already built for `CheckRule` (K2b) |
| Operation: **remote command** in response to a problem | Run a command/script on the host when a trigger fires | ❌ not in the notify path | **reject here** — this is auto-remediation; belongs to the L-series orchestration/remediation layer, not notifications |

### Bug found while analyzing (not a Zabbix gap — a real defect)

**K13-fix — OU scope + GPO precedence is stored & API-configurable on notification rules but IGNORED at
dispatch.** `NotificationRule` carries `ou_id`/`enforced`/`link_order` (`models.py:1056-1058`) and the
API accepts + PATCH-toggles them (`api/notifications.py:42-44,125-139`), but the send path never reads
them: `dispatch` selects only `enabled` rules (`notification.py:150`) and `rule_matches`
(`notification.py:60-78`) filters on event/severity/host/service/tag only — never `ou_id`. So a rule
scoped to one OU fires for **every** host, and `enforced`/`link_order` do nothing. This mirrors the
monitoring side's GPO resolution (services/gpo.py, used by check_rules) but was never wired into
notifications. **Recommend fixing** by resolving the effective notification rules per host through the
same `gpo.resolve_winner`/OU-ancestry path `resolve_effective_rule` uses, so a notification rule
scoped to an OU only fires for hosts under that OU. This is a logic change to the dispatch path — to
be confirmed before implementing.

**Decisions (awaiting user).** Nothing implemented in this batch yet — this is the analysis pass. My
recommendation, in priority order: **(1) K13-fix** the OU/GPO dispatch bug (it silently breaks a
feature that already looks configured); **(2)** message templates + the minimal built-in-macro set +
a `script` media channel (these three compound — a scriptable channel with a templated, macro-filled
body is what makes notifications genuinely useful); **(3)** renotify-until-ack + per-rule time window
(the high-value slices of escalation); **defer** full multi-step escalation, user macros, per-user
media, secret/vault macros; **reject for now** SMS, macro contexts/functions, and remote-command
operations (the last belongs to the remediation layer). Per the project rule, the logic-changing items
(K13-fix and anything touching the dispatch/resolution path) are confirmed with the user before any
code.

## Batch 6 — Ch.7e Configuration: Users/permissions, Secrets, Scheduled reports, Data export

Read: [config/users_and_usergroups/permissions](https://www.zabbix.com/documentation/7.0/en/manual/config/users_and_usergroups/permissions),
[config/secrets](https://www.zabbix.com/documentation/7.0/en/manual/config/secrets),
[reports/scheduled](https://www.zabbix.com/documentation/7.0/en/manual/web_interface/frontend_sections/reports/scheduled),
[appendix real-time export](https://www.zabbix.com/documentation/7.0/en/manual/appendix/install/real_time_export).

Bossman side verified file:line. Summary of what exists today: a 2-role (`admin`/`operator`) local
user DB with JWT+bcrypt login (`db/models.py:277-288`, `services/auth.py:28`), SHA-256-hashed API
tokens (`models.py:291-303`) and a shared-secret agent enrollment (`api/enroll.py:37-61`). A Go
per-tool ACL exists **on the agent** (`internal/authz/acl.go`) but does not govern Bossman's API. No
SSO, no secrets manager, no reports, no bulk export.

| Feature (Zabbix) | Detail | yolo-man status | Disposition (recommendation) |
|---|---|---|---|
| **User types / role ceiling** (User · Admin · Super Admin) | Three built-in tiers, each a ceiling on what a custom role can do | 🟡 two role *names* exist (`admin`/`operator`, `models.py:288`) but they are **never checked** anywhere | see K14-fix below |
| **Custom roles** restricting menu sections / services / modules / **API methods** / frontend actions | Fine-grained revoke-only role editor | ❌ nothing comparable in Bossman | **defer** — big; only meaningful after basic role enforcement (K14-fix) lands |
| **User groups → per-host-group permissions** (read / read-write / **deny**, deny-wins, access only via group membership) | Resource authz is entirely group-mediated and host-group-scoped | ❌ no user groups, no per-host-group permissions, no deny semantics (`grep` empty) | **defer** — bundle with real RBAC + the multi-tenant `tenant_id` work; large block |
| **Authentication: LDAP / SAML / HTTP / MFA** | Directory SSO + second factor | ❌ local password DB only (`api/auth.py:33-43`); OAuth explicitly rejected for MCP (`mcp/auth.py:5-10`) | **defer** — example.internal has AD, so LDAP/SAML SSO is plausibly wanted eventually; not now. MFA **reject for now** |
| **User & API-token management** (create/list/revoke users, roles, tokens from the UI/API) | Full admin CRUD in the frontend | ❌ tokens/users can ONLY be created via `scripts/seed_admin.py` + test helpers; no router, no UI (`main.py:17,158` mounts login only) | **implement (small, high value)** — a minimal admin CRUD for users + API tokens (create/list/revoke); prerequisite for anyone but the seed admin to exist |
| **Secret user macros** (masked value in UI) | `{$PASSWORD}` stored masked | ❌ no macro system at all (see Batch 5 #8) | **defer** — bundle with the Batch-5 macro decision |
| **Vault secrets** (HashiCorp / CyberArk references for macros + DB creds) | External secret store, no secret in Zabbix DB | ❌ all secrets are plain env vars (`config.py:80,103,124,135`); TLS key on disk with `NoEncryption()` (`services/keys.py:58`) | **defer** — real hardening, but needs a vault to exist in the environment first |
| **Scheduled reports** (dashboard → PDF via web service, emailed daily/weekly/monthly) | Headless-Chromium PDF render on a schedule to users/groups | ❌ no report generation, no PDF lib, no scheduler for it (`cron*.go` is a host-config module, not a Bossman reporter) | **reject for now** — heavy infra (headless browser) for low marginal value; the live dashboards + availability views already cover the "how are we doing" question |
| **Real-time data export** (NDJSON of history / trends / events to `ExportDir`, `ExportType`/`ExportFileSize`) | Continuous file export for external consumers (SIEM/data lake) | ❌ only per-event email/webhook (`notification.py:95-125`); read APIs return JSON to the UI, no bulk/stream dump | **defer** — a scoped events/audit **export endpoint** (or an outbound stream) is the useful 20%; revisit if a concrete downstream consumer appears |
| **Audit log** (who changed what, viewable + exportable) | Full config-change audit with export | 🟡 the Go agent writes JSON audit lines to stderr/journal (`audit.New`, agent-side); plan-runs are audited (`runs.py`); no Bossman-wide config-change audit log or its export | **defer** — partial today; a unified Bossman audit trail pairs naturally with the RBAC work |

### Bugs found while analyzing (real security defects, not Zabbix gaps)

**K14-fix — the `admin`/`operator` roles are stored but NEVER enforced; every authenticated caller has
full access.** Each protected route depends on `get_current_identity` bound to a throwaway `_identity`
parameter (underscore = never read), e.g. `api/admin.py:70,105,123`, `api/orchestration.py:105-391`,
`api/templates.py:58-344`. A repo-wide search for `identity.role`/`== "admin"`/`403`/permission checks
in `bossman/bossman/api` + `services` returns **zero** hits. Concretely: an `operator` JWT can delete
templates/graphs/check-rules, run housekeeping, change the log level, delete orchestration links — and
**a read-only user cannot exist**. **Recommend** a minimal enforcement layer: a `require_role(...)`
dependency gating destructive endpoints to `admin`, and a real read-only role (`viewer`) — the smallest
step that makes the stored roles mean something. Logic change → confirm before coding.

**K15-fix — agent bearer tokens are stored in plaintext in the DB** (`Agent.token`, `models.py:89`),
unlike `ApiToken` which is SHA-256-hashed (`services/auth.py:99-107`). A DB read (backup leak, SQL
injection, operator over-access) hands over every agent's push/poll credential in the clear.
**Recommend** hashing agent tokens the same way ApiToken already is (compare by hash), or at minimum
documenting the accepted risk. Touches enrollment + the poll/push auth path → confirm before coding.

**Decisions (awaiting user).** Analysis pass only — no code. Priority recommendation: **(1) K14-fix**
(role enforcement + a read-only role — the biggest real gap here; "logged-in = full access" is a
liability once more than one person has a login); **(2) K15-fix** (hash agent tokens); **(3)** the
user/API-token management CRUD (so accounts exist without the seed script). **Defer** full user-group/
per-host-group RBAC, custom roles, LDAP/SAML SSO, vault secrets, secret macros, a unified audit log,
and a scoped data-export endpoint. **Reject for now** scheduled PDF reports and MFA. Both K-fixes are
logic changes to the auth path and are confirmed with the user before any code.

## Batch 7 — Ch.8 Service Monitoring + Ch.9 Web Monitoring + Ch.10 VM Monitoring

Read: [it_services/service_tree](https://www.zabbix.com/documentation/7.0/en/manual/it_services/service_tree),
[web_monitoring](https://www.zabbix.com/documentation/7.0/en/manual/web_monitoring),
[vm_monitoring](https://www.zabbix.com/documentation/7.0/en/manual/vm_monitoring).

Bossman side verified file:line. **The critical distinction:** Bossman's `Service` (`db/models.py:967`)
is a per-host CheckMK-style *check result*, not a composable business service — there is only a
per-host worst-wins `state_rollup` (`monitoring.py:918,1017`), no service-of-services tree above it.
Availability is computed as OK% of monitored time (`compute_availability`, `monitoring.py:697`), and
the UI "SLA bar" (`host-detail.component.ts:1207-1266`) renders that OK% + a state-duration bar — with
no SLA target and no compliant/breach verdict. Scheduled downtime exists (`Downtime`, `models.py:1089`)
but suppresses problems/notifications only; it is **not** subtracted from the availability denominator.
No web-scenario feature and no hypervisor/VMware discovery exist.

| Feature (Zabbix) | Detail | yolo-man status | Disposition (recommendation) |
|---|---|---|---|
| **Business-service tree** (Ch.8) — services composed of child services/hosts, multi-parent | A named service with children; status rolls up from children | ❌ `Service` is per-host, no parent/child (`models.py:967`); only per-host worst-wins rollup (`monitoring.py:1017`) | **defer** — genuine value ("is the webshop healthy" = composite of app+db+lb), but a sizeable feature (tree model + calc + UI); the OU tree + `state_rollup` are reusable building blocks |
| **Service status-calculation rules** | most-critical-of-child · most-critical-if-all · if-≥N/≥N%-children · integer weights (0–1e6) · propagation ±severity | ❌ only worst-wins for one host's own services | **defer** — part of the business-service block above |
| **Problem-tag → service mapping** (AND-logic tags bind problems to leaf services) | Leaf services adopt the severity of matching problems | ❌ no tag layer on services (problems key directly to the per-host service) | **defer** — part of the business-service block |
| **SLA / SLO** — target %, uptime/downtime budget, compliant/breach verdict, period SLA report | Explicit SLO with target and pass/fail over a window | 🟡 availability OK% exists (`compute_availability`, `monitoring.py:697`; API `api/monitoring.py:216`) but **no target, no verdict, no multi-service report** | **implement (small)** — add an SLA target % + compliant/breach verdict on top of the existing OK% calc; the numeric groundwork is already there |
| **Web scenario** (Ch.9) — multi-step HTTP: per-step URL/method/POST/expected-status/required-string/timeout → response-time/download-speed/last-error metrics | First-class synthetic-HTTP monitoring | ❌ none (built-ins are only CPU/Mem/Disk/Uptime, `collect/checks.go:122`) | **implement (scoped v1)** — a single-request HTTP check (URL, expected status, response-time threshold) feeding the existing services/graphs/check-rules pipeline; defer true multi-step scenarios. High value ("is the site up + how fast") |
| Web check via existing plugins/modules | `uri`/`get_url` modules + curl-in-pipeline are HTTP-capable | 🟡 generic config-management only (`modules/uri.go:29`, `server/modules.go:69`; curl in `configs/commands.yaml`) — one-shot actions, no schedule/perf-metric/expected-string contract | (covered by the scoped web check above — reuse the module for the fetch, add the check/metric contract) |
| **VMware/vCenter/ESXi discovery** (Ch.10) — LLD of hypervisors/VMs/datastores, auto host-creation, VM metrics via SOAP | Server-side hypervisor collector | ❌ only a guest-side DMI virtualization fact (`inventory.go:324`); no discovery/API integration | **reject for now** — big integration, and the environment already has separate `vcenter-api`/`proxmox-api` skills + a proxmox→netbox importer for inventory; revisit only if hypervisor-level metrics become a Bossman requirement |
| Auto host-creation for guests / low-level discovery (LLD) | Zabbix creates hosts from discovered VMs via templates | ❌ no LLD mechanism at all (grep empty) | **defer** — LLD generally (not just VMs) is a bigger discovery feature; baseline #17 already tracks the discovery gap |

### Correctness gap found while analyzing

**K16-fix — scheduled downtime is NOT excluded from the availability/SLA denominator.** `Downtime`
(`models.py:1089`) suppresses problems + notifications (`monitoring.py:552-616`,
`notification.py:199-212`), but `compute_availability` (`monitoring.py:697`) reads only
`ServiceStateHistory` and never subtracts downtime windows. So planned maintenance counts as
non-OK time and drags down the reported OK% — the opposite of what an SLA view should do (Zabbix
explicitly excludes maintenance from SLA, and this module's own docstring, `monitoring.py:679-684`,
states the intent that "soft blips don't count against an SLA"). **Recommend** subtracting
overlapping `Downtime` windows from the availability denominator (or reporting a separate
"scheduled" slice that doesn't count as downtime). Logic change to the availability calc — confirm
before coding.

**Decisions (awaiting user).** Analysis pass only — no code. Priority recommendation: **(1)** the
scoped **web/HTTP check** (highest new-value: synthetic uptime + response-time for services, a very
common real need); **(2) K16-fix** downtime-excluded availability + an **SLA target/verdict** on top
of the existing OK% (small, and makes the "SLA bar" honest); **defer** the full business-service
tree (composition + status-calc rules + problem-tag mapping + LLD); **reject for now** VMware/vCenter
discovery (external tooling already covers inventory). The logic-changing items (K16-fix, and anything
touching the availability calc) are confirmed with the user before any code.
