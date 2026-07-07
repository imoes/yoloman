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
- [ ] Batch 3 — Ch.7b Configuration: Triggers, Events, Event correlation, Tagging
- [ ] Batch 4 — Ch.7c Configuration: Visualization, Templates
- [ ] Batch 5 — Ch.7d Configuration: Notifications, Macros
- [ ] Batch 6 — Ch.7e Configuration: Users/permissions, Secrets, Scheduled reports, Data export
- [ ] Batch 7 — Ch.8 Service Monitoring + Ch.9 Web Monitoring + Ch.10 VM Monitoring
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

Read: [manual/concepts](https://www.zabbix.com/documentation/7.0/en/manual/concepts) (overview) +
[manual/concepts/server](https://www.zabbix.com/documentation/7.0/en/manual/concepts/server) (full detail incl. High Availability + runtime control).

Server = "the central process that performs polling and trapping of data, calculates triggers, and
sends notifications to users." Its internal process-thread breakdown (agent/SNMP/HTTP/ICMP/IPMI/
Java/ODBC pollers, history syncer, preprocessing manager/worker, trapper, alert manager/alerter/
escalator, task manager, configuration syncer, discovery/LLD manager+worker, housekeeper, self-
monitoring, connector manager/worker, report manager/writer, proxy group manager, timer, web
monitoring) is Zabbix's own internal architecture, not a checklist of separate user-facing
features — most of it maps to concepts already tracked in the baseline (item types #36, discovery
#17/#40, data export #12, scheduled reports #11, web monitoring #37) and will get full treatment
when those chapters are read (Ch.7, Ch.9, Ch.15). Three items are new or meaningfully sharpen an
existing baseline entry:

| Feature (Zabbix) | Detail | yolo-man status | Note |
|---|---|---|---|
| High Availability (server) | Multiple server nodes, active/standby, database-coordinated failover, configurable failover delay (min. 10s, `ha_set_failover_delay`), node registration/removal (`ha_status`, `ha_remove_node`) | ❌ missing (sharpens baseline #43) | Bossman is single-instance; no multi-node coordination, no failover of any kind. A Bossman crash/restart is a monitoring outage until it comes back. |
| Housekeeping (as a live, configurable, triggerable process) | Per-data-type retention, `housekeeper_execute`/`trigger_housekeeper_execute` runtime-triggerable without restart | 🟡 sharpens baseline #21 | yolo-man's retention (14/30/30 days) is hardcoded in Alembic migrations — not configurable, not manually triggerable, no per-table breakdown of what's being cleaned. |
| Runtime operational control plane | Live cache reload, log-level increase/decrease, diagnostics dump (`diaginfo`), profiling toggle, secrets reload — all without restarting the process | ❌ missing (new) | Bossman has no equivalent: no live log-level control, no diagnostics/queue-depth dump endpoint, no way to force a reload of anything short of a full redeploy (which is exactly the friction we've hit this session restarting the module-translation background job after every Bossman deploy). |

**Decisions (user, 2026-07-07):**
- High Availability → **defer** (roadmap; genuine multi-node HA is a large, standalone block, sensible after the rest of this analysis lands)
- Configurable/triggerable housekeeping → **implement now** → new Block K1
- Runtime operational control plane (diagnostics + live log-level) → **implement now** → new Block K2
