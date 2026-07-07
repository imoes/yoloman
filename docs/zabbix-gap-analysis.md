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

- [ ] Batch 1 — Ch.3 Zabbix Processes (light)
- [ ] Batch 2 — Ch.7a Configuration: Hosts/groups, Items
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

## Batch 1 — Ch.3 Zabbix Processes

*(pending — not yet read)*
