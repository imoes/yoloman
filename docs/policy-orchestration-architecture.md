# Policy & Orchestration Architecture (Bossman L-series)

> **Status & scope.** This is the authoritative reference plan for turning Bossman from a
> monitoring tool into a shared **policy + orchestration system** organised around an OU tree
> (AD/GPO-style). It integrates the user's full architecture brief verbatim in content, adapted to
> the foundation decisions already agreed for this codebase (see "Bossman adaptations" below).
> Blocks **L1** (OU tree, orchestration plans/links, host groups, compiled_host_state) and **L2**
> (approval gate, global YOLO-MAN switch, MCP tools) are **implemented**; **L3+** is the roadmap
> this document specifies. Section numbers mirror the brief's §16 result format.

---

## Bossman adaptations vs. the reference brief (agreed 2026-07-08)

These are the deliberate deviations from a generic greenfield design — everything else follows the
brief as written.

1. **`agents`, not `hosts`.** Bossman's host table is `agents` (an enrolled node agent / "Duppy").
   Everywhere the brief says `hosts`, read `agents`. A nullable `agents.ou_id` places a host in
   exactly one OU; `agents.tenant_id` (DB-default-seeded) scopes it.
2. **Additive, type-specific rule tables — not one generic `rules`/`rule_sets`/`rule_links`.** The
   brief models all rules in a single `rules` table with a `rule_type` discriminator. Bossman keeps
   its existing, tested, type-specific tables (`check_rules`, `notification_rules`,
   `orchestration_plans`/`_versions`/`_links`, `host_groups`) and binds each to the OU tree. The
   *behaviour* (rule + scope + inheritance + merge) is identical; the storage stays typed. The brief's
   `rules`/`rule_links` concepts map onto these tables' `scope_*`/`ou_id`/`enforced`/`link_order`
   columns. This was an explicit foundation decision ("additiv, keine generische rules-Tabelle").
3. **Multi-tenant from day one.** Every new table carries `tenant_id`; a fixed default tenant is
   seeded and existing rows backfilled.
4. **`ltree` for the OU path** + a classic `parent_id` for cheap UI tree ops (both, per the brief §1).
5. **The orchestration executor already exists.** The brief's "agent runs idempotent steps" is
   Bossman's existing plan engine (`services/plan_engine.py`, `plan_loader.py`) + ~50 native-Go
   idempotent modules behind `POST /api/v1/tools/{name}`. No new step runtime is built; plans compile
   down to these.
6. **Approval = "YOLO-MAN mode".** The brief's approval requirements (§22) are implemented as the
   per-link `require_approval`/`auto_apply` gate plus a global `system_settings.yolo_mode` switch
   (auto vs. manual, like Claude Code's own toggle). MCP can never self-approve.
7. **Controller push reuses the existing controller→agent RPC.** Bossman already dials agents (pull
   for metrics, RPC for plan steps); the agent never connects out except at enrollment. Desired-state
   delivery (L4+) builds on `services/agent_client.py`.

---

## 1. Kurzfazit (executive summary)

A hierarchical **OU tree** (PostgreSQL `ltree`) is the primary organisational axis. Hosts (`agents`)
live in exactly one OU and additionally carry cross-cutting **labels/tags**. Monitoring, threshold,
notification, schedule, agent-config, discovery and maintenance/suppression policy is expressed as
**rules scoped to a level of the tree** (global → OU chain → host), inherited top-down with exact
**GPO semantics** (closest wins; `enforced` can't be overridden and pierces `block_inheritance`).
A **compiler/reconciler** turns rules + tree + labels into a per-host **`compiled_host_config`**
(desired state) with a `generation` + `config_hash` + `explain_plan`, recomputed incrementally on
change via a **transactional outbox** (LISTEN/NOTIFY only as a wake-up signal). The **controller
pushes** desired state to agents over the existing mTLS channel (single firewall rule Bossman →
agent; the agent never dials out); agents verify the generation, atomically swap, keep a rollback
copy, and ack/nack in the push response. Orchestration plans (roles/clusters) live in the same tree and
"what is orchestrated is monitored" (generated monitoring). Everything is versioned, audited,
explainable, multi-tenant, and RBAC/mTLS-secured.

## 2. Zielarchitektur

```
+-----------------------------------------------------------+
| UI (Angular GPO console)  |  REST API  |  MCP facade (AI) |
|  OU tree · rules · plans · explain · dry-run · impact     |
+----------------------------+------------------------------+
                             | writes (rule change + outbox event, same TX)
                             v
+-----------------------------------------------------------+
| PostgreSQL                                                 |
|  ou_nodes(ltree) · agents · host_labels · check_rules ·    |
|  notification_rules · orchestration_plans/_versions/_links |
|  compiled_host_config · policy_events · controller_outbox ·|
|  agent_sessions · agent_config_delivery · agent_acks ·     |
|  audit_log · system_settings                               |
+----------------------------+------------------------------+
        ^ LISTEN/NOTIFY 'policy_changed' (signal only)       
        |                    |
        |                    v
+-----------------------------------------------------------+
| Controller / Reconciler workers                            |
|  outbox consumer → affected-host set → compile desired     |
|  state (Policy Compiler + Orchestration Compiler) →        |
|  write compiled_host_config generation → enqueue delivery  |
+----------------------------+------------------------------+
                             | Controller → Agent PUSH (POST /api/v1/config/apply, mTLS)
                             v
+-----------------------------------------------------------+
| Agent (Duppy)                                              |
|  verify sig/generation/schema → atomic swap → keep rollback|
|  → run checks + idempotent orchestration steps → ack/nack  |
+-----------------------------------------------------------+
```

Two compilers, one output: the **Policy Compiler** (monitoring/threshold/notification/schedule/
agent-config from rules) and the **Orchestration Compiler** (roles/plans/cluster memberships) both
feed the single `compiled_host_config`. Orchestration additionally emits **generated monitoring**
that merges into the monitoring section.

## 3. Datenmodell (PostgreSQL)

Conventions: every table has `id uuid PK default gen_random_uuid()`, `tenant_id uuid NOT NULL`,
`created_at`/`updated_at timestamptz`, `deleted_at timestamptz` (soft delete), and where a human/
actor causes the change, `created_by`/`updated_by`. FKs are `ON DELETE CASCADE` for owned children,
`SET NULL` for optional references.

```sql
-- OU tree: ltree path (fast ancestor/descendant) + parent_id (cheap UI ops).
CREATE EXTENSION IF NOT EXISTS ltree;
CREATE TABLE ou_nodes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    parent_id uuid REFERENCES ou_nodes(id) ON DELETE CASCADE,     -- NULL = tenant root
    name text NOT NULL,                    -- free display name ("Munich Prod")
    path text NOT NULL,                    -- human slash path "/Germany/Munich/Prod"
    ltree_path ltree NOT NULL,             -- sanitized labels: Germany.Munich.Prod
    block_inheritance boolean NOT NULL DEFAULT false,   -- GPO "Block Inheritance"
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (tenant_id, path)
);
CREATE INDEX ix_ou_nodes_ltree_gist ON ou_nodes USING gist (ltree_path);
CREATE INDEX ix_ou_nodes_parent ON ou_nodes (parent_id);

-- agents (existing table; L1/L3 additive columns shown)
ALTER TABLE agents ADD COLUMN tenant_id uuid REFERENCES tenants(id) ON DELETE SET NULL
    DEFAULT '00000000-0000-0000-0000-000000000001';
ALTER TABLE agents ADD COLUMN ou_id uuid REFERENCES ou_nodes(id) ON DELETE SET NULL;

-- Cross-cutting labels (brief §2). Existing agents.tags JSONB already stores name:value pairs;
-- host_labels is the normalized, indexable form for label-selector rule conditions.
CREATE TABLE host_labels (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    agent_id uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    key text NOT NULL,                     -- os, env, site, role, customer, agent_type
    value text NOT NULL,
    UNIQUE (agent_id, key)
);
CREATE INDEX ix_host_labels_kv ON host_labels (tenant_id, key, value);

-- Rule tables share a common "scoped rule" shape (Bossman-typed, not one generic table):
--   scope_type, scope_ou_id/scope_value, enforced, enabled, link_order, conditions(jsonb),
--   merge_strategy. Shown here on check_rules; notification_rules mirrors it.
ALTER TABLE check_rules
    ADD COLUMN scope_ou_id uuid REFERENCES ou_nodes(id) ON DELETE CASCADE,   -- scope_type='ou'
    ADD COLUMN enforced boolean NOT NULL DEFAULT false,
    ADD COLUMN link_order integer NOT NULL DEFAULT 100,
    ADD COLUMN conditions jsonb NOT NULL DEFAULT '{}',   -- label selector, e.g. {"os":"linux"}
    ADD COLUMN merge_strategy text NOT NULL DEFAULT 'override';
-- scope_type now IN ('global','ou','group','host'); host is the closest normal level.

ALTER TABLE notification_rules
    ADD COLUMN ou_id uuid REFERENCES ou_nodes(id) ON DELETE CASCADE,   -- NULL = global
    ADD COLUMN enforced boolean NOT NULL DEFAULT false,
    ADD COLUMN link_order integer NOT NULL DEFAULT 100,
    ADD COLUMN conditions jsonb NOT NULL DEFAULT '{}';

-- Orchestration (L1, implemented): plans + immutable versions + links, links already carry
-- ou_id/host/group/global + enforced + enabled + link_order + auto_apply + require_approval + status.
-- (See models.py: OrchestrationPlan/Version/Link.)

-- Compiled desired state (L1, implemented; brief §6 fields):
CREATE TABLE compiled_host_config (      -- Bossman name: compiled_host_state
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    agent_id uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    generation bigint NOT NULL,          -- monotonic per host
    config_hash text NOT NULL,           -- sha256 of canonical JSON
    state jsonb NOT NULL,                -- effective_checks + effective_thresholds + effective_notifications + orchestration
    explain jsonb NOT NULL,              -- explain_plan: per setting -> source rule id + level
    source_rule_ids uuid[] NOT NULL DEFAULT '{}',
    is_current boolean NOT NULL DEFAULT true,
    compiled_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, agent_id, generation)
);
CREATE UNIQUE INDEX uq_compiled_current ON compiled_host_config (tenant_id, agent_id)
    WHERE is_current;

-- Eventing / outbox (L4):
CREATE TABLE policy_events (
    id bigserial PRIMARY KEY,
    tenant_id uuid NOT NULL,
    kind text NOT NULL,                  -- rule_changed | ou_changed | host_moved | label_changed | plan_changed
    payload jsonb NOT NULL,              -- what changed (ids), NOT the full config
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE controller_outbox (
    id bigserial PRIMARY KEY,
    tenant_id uuid NOT NULL,
    event_id bigint NOT NULL REFERENCES policy_events(id),
    status text NOT NULL DEFAULT 'pending',   -- pending|processing|done|failed
    attempts integer NOT NULL DEFAULT 0,
    last_error text,
    available_at timestamptz NOT NULL DEFAULT now(),   -- backoff
    processed_at timestamptz
);
CREATE INDEX ix_outbox_ready ON controller_outbox (available_at) WHERE status = 'pending';

-- Delivery + acks (L4):
CREATE TABLE agent_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    agent_id uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    mode text NOT NULL,                  -- push (controller-initiated; the agent never pulls)
    last_seen_generation bigint,
    last_ack_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE agent_config_delivery (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    agent_id uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    generation bigint NOT NULL,
    config_hash text NOT NULL,
    status text NOT NULL DEFAULT 'pending',   -- pending|sent|acked|nacked|failed
    attempts integer NOT NULL DEFAULT 0,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (agent_id, generation)
);
CREATE TABLE agent_acks (
    id bigserial PRIMARY KEY,
    tenant_id uuid NOT NULL,
    agent_id uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    generation bigint NOT NULL,
    result text NOT NULL,                -- ack | nack
    detail jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Audit (every rule/OU/link change):
CREATE TABLE audit_log (
    id bigserial PRIMARY KEY,
    tenant_id uuid NOT NULL,
    actor text NOT NULL,                 -- user or api_token or 'mcp-facade'
    action text NOT NULL,                -- create|update|delete|link|enforce|approve|reject
    object_type text NOT NULL,
    object_id uuid,
    before jsonb, after jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
```

Tables from the brief already present under other names: `check_definitions`/`checks` ≈ the module/
check catalog (`configs/modules.d`, tools.d `check:` tasks); `check_assignments` ≈ `check_rules`
with `scope_type='ou'|'host'`; `notification_targets`/`notification_routes` ≈ `notification_rules`
+ its `channel`/`target` (to be normalized when routing grows).

## 4. Vererbungs- und Konfliktmodell (GPO semantics — verified against Microsoft Learn)

**Processing order (LSDOU-analogue), top-down; each later level overrides earlier → closest wins:**
`global` (≈ Domain) → OU chain root→…→host-OU (parent before child) → `host` (≈ closest). `group`/
label conditions are **filters** (who a rule applies to), not a precedence level.

**Level precedence, normal (non-enforced):** `host` > deeper OU > higher OU > `global`. Tie within
one level → lowest `link_order`, then newest `created_at`.

**Enforced** (link property): an enforced rule at a higher level **cannot** be overridden by lower
levels, and is **immune to block_inheritance**. Among multiple enforced rules, the one at the
**highest** level wins (global-enforced beats OU-enforced beats deeper-OU-enforced); tie → lowest
`link_order`.

**Block Inheritance** (OU/container property): if any OU on the path has `block_inheritance=true`,
all **non-enforced** rules from levels **above** that OU are discarded (higher OUs + global);
rules at that OU and below, plus all enforced rules, still apply.

**Merge strategy per rule type:**

| Rule type            | Default merge      | Notes |
|----------------------|--------------------|-------|
| Check Assignment     | `append` + `deny/remove` | union of enabled checks; a `deny` rule removes a check |
| Threshold            | `override` (or `min/max`) | closest/enforced wins; `min`/`max` optional for safety floors |
| Notification         | `append`           | union of routes; `deny` removes a route |
| Schedule             | `override`         | closest interval wins |
| Agent Config         | `merge`            | JSON objects deep-merged, closest key wins |
| Discovery            | `append`           | union of discovery rules |
| Suppression/Maint.   | `append`           | any matching downtime suppresses |

`first_match`/`last_match` are available per rule for ordered decision tables.

## 5. Policy-Evaluation-Algorithmus

```
function compile_host_desired_state(agent):
    ou_chain   = ancestry(agent.ou_id)            # ltree: root → host-OU, ordered
    blocked_at = first OU in ou_chain with block_inheritance = true   # or none
    labels     = load_host_labels(agent)

    for each rule_type:
        candidates = rules of this type where scope reaches agent:
            global, any OU in ou_chain, host==agent, matching group/label conditions
        # Block inheritance: drop non-enforced candidates above blocked_at
        if blocked_at:
            candidates = [c for c in candidates
                          if c.enforced or level_of(c) >= level_of(blocked_at)]
        winner-set = resolve per (setting key) using _resolve_gpo_winner:
            if any enforced: pick highest-level enforced (tie: lowest link_order)
            else:            pick closest/deepest level  (tie: lowest link_order, then newest)
        effective[rule_type] = apply merge_strategy(winner-set)   # append/override/merge/deny/min-max
        record explain: setting -> {rule_id, level, path, enforced, reason}

    generated = derive_monitoring_from_orchestration(effective.orchestration)
    state = merge(effective.monitoring, generated, effective.notifications, effective.orchestration)
    hash  = sha256(canonical_json(state))
    if hash != current_hash(agent):
        gen = next_generation(agent)
        save compiled_host_config(agent, gen, hash, state, explain, source_rule_ids)
        enqueue agent_config_delivery(agent, gen, hash)   # L4
    return state
```

`_resolve_gpo_winner(candidates, ou_chain)` is the single shared function used by the Policy Compiler,
the orchestration-assignment resolver, and monitoring's `resolve_effective_rule`.

## 6. Controller-Agent-Protokoll (PUSH only)

Agent never reads the DB directly, and — decisively — **never dials out**. Delivery is
**controller-initiated PUSH** over the existing mTLS channel Bossman already uses to poll the agent.
This keeps the firewall to a **single rule (Bossman → agent)**; there is no agent-facing ingress on
Bossman at all.

- **Push:** the reconciler (`services/reconciler.py`) recompiles an affected host, and if its
  generation changed, POSTs to the agent's own `POST /api/v1/config/apply` with
  `{generation, config_hash, state}`. The agent's JSON response (`{status: "applied"|"unchanged",
  generation}`) **is** the ack — recorded as the `agent_config_delivery` status (`acked`) plus an
  `agent_acks` row. A transport/HTTP failure records `nacked` (or `failed` after N attempts) and the
  outbox retries with backoff; a single unreachable agent never stalls the queue.

Agent apply discipline (`internal/desiredstate/applier.go`): receive the pushed delivery → verify
**generation** is newer (a stale/replayed push returns `unchanged`, never downgrades) → **atomically
swap** config (temp-file + rename) → keep the previous generation for **rollback** → reply
`applied`/`unchanged`. The apply endpoint is **write-gated** (a read-only agent returns `403`).
Orchestration executions use the existing plan-step endpoints (`POST /api/v1/tools/{name}`), reported
per step.

## 7. PostgreSQL-Eventing / Outbox

**Transactional outbox:** a rule/OU/label/plan change writes both the domain row **and** a
`policy_events` + `controller_outbox` row in the **same transaction**. A `LISTEN/NOTIFY
'policy_changed'` fires as a **wake-up signal only** (payload = event id, well under the 8 kB limit —
never the config). Controller workers: `SELECT … FROM controller_outbox WHERE status='pending' AND
available_at<=now() FOR UPDATE SKIP LOCKED`, compute the **affected-host set** (ltree subtree query
for OU changes, label match for label changes, direct for host changes), recompile those hosts, write
new `compiled_host_config` generations, **push each changed generation to its agent's
`POST /api/v1/config/apply`** and record the ack in `agent_config_delivery` + `agent_acks`, then mark
the outbox row `done`. Failures increment `attempts`, set `available_at = now() + backoff`, and after
N attempts move to a **dead-letter** state.

## 8. API-Design (REST, `/api/v1`)

- OU: `POST /ou`, `PATCH /ou/{id}` (rename, `block_inheritance`), `POST /ou/{id}/move`,
  `DELETE /ou/{id}`, `GET /ou`, `GET /ou/{id}/objects` (all rules/objects at an OU), `GET
  /ou/{id}/ancestry`.
- Host: `PUT /agents/{id}/ou`, `PUT /agents/{id}/labels`.
- Rules (per type): `POST/PUT/DELETE /check-rules`, `/notification-rules`, … with `scope_*`,
  `ou_id`, `enforced`, `link_order`, `conditions`, `merge_strategy`; `PATCH …/{id}/enforced`,
  `PATCH …/{id}/enabled`, `PATCH …/{id}/link-order`.
- Orchestration (L1/L2, implemented): `/orchestration/plans`, `/versions`, `/links`,
  `/links/{id}/approve|reject`, `/pending-links`, `/preview-link`; `system/yolo-mode`.
- Effective/explain: `GET /agents/{id}/desired-state`, `GET /agents/{id}/explain?check=…`.
- Agent (on the AGENT, pushed to by Bossman): `POST /api/v1/config/apply`, `GET /api/v1/state`. There
  is no agent-facing endpoint on Bossman — the agent never calls in.
- Ops: `POST /reconcile` (manual trigger), `POST /rules/dry-run`, `POST /rules/impact`
  ("which hosts would change?").

## 9. UI-Konzept (Angular GPO console)

- **Left: OU tree** (`@angular/cdk/tree`), right-click context menu (`@angular/cdk/menu`) to create
  OUs and objects, toggle `Enforced`/`Link Enabled` (on objects) and `Block Inheritance` (on OUs) —
  1:1 with GPMC.
- **Middle: hosts + sub-OUs** of the selected node.
- **Right: inherited + local rules** with a status lamp per rule: **active · overridden · blocked ·
  enforced · ineffective** — matching GPMC's inheritance tab.
- **Explain** button per host/check (renders `explain_plan`); **Preview/Dry-Run** before activation;
  **Diff** before/after a change; **bulk change with impact count**.

## 10. Sicherheitsmodell

mTLS + signed agent tokens (existing `keys.py` client keypair); **RBAC** for UI/API (the `role`
column exists — enforcement is a tracked gap); optional **PostgreSQL Row-Level Security** keyed on
`tenant_id` for hard multi-tenancy; **audit_log** on every change; **signed desired-state payloads**
(HMAC/ed25519) with generation + schema checks; **no direct DB access from agents**; **rate limits +
replay protection** (nonce/generation) on agent endpoints; **rollback** to the previous generation.
Orchestration writes obey the L2 approval gate (auto vs. manual / YOLO-MAN); MCP can never
self-approve or enable YOLO-MAN.

## 11. Skalierungsstrategie

Incremental reconciliation (only affected hosts, via ltree subtree + label queries); GiST `ltree`
indexes; materialized `compiled_host_config`; `config_hash` to skip unchanged downloads
(`304`); batch reconciliation; worker queue with `FOR UPDATE SKIP LOCKED`; idempotent delivery keyed
on `(agent_id, generation)`; retry with exponential backoff; dead-letter for poison deliveries.

## 12. Beispiel: OU-Baum + finale Host-Konfiguration

Tree: `/` → `/Germany` → `/Germany/Munich` → `{Prod, Test}`, plus `/Germany/Kassel`, `/Germany/Giessen`.
Hosts: `db01` & `web01` in `/Germany/Munich/Prod` (`os=linux`), `win-file01` in `/Germany/Kassel`
(`os=windows`). Rules: Root→Ping(all); `/Germany`→NOC-notify **and** enforced Security-Baseline
check; `/Germany/Munich`→agent check every 60 s; `/Germany/Munich/Prod`→CPU warn 85/crit 95;
`/Germany/Munich/Test`→CPU warn 95/crit 99 **+ block_inheritance**; host-exception `db01`→disk
`/var/lib/postgresql` warn 80/crit 90.

**Effective config for `db01`** (`/Germany/Munich/Prod`):

| Setting | Value | Source | Why |
|---|---|---|---|
| Ping check | on | Root (`/`) | inherited, no override |
| Security-Baseline check | on, **locked** | `/Germany` (enforced) | enforced → can't be disabled downstream |
| NOC notification | on | `/Germany` | inherited |
| Agent check interval | 60 s | `/Germany/Munich` | inherited |
| CPU threshold | warn 85 / crit 95 | `/Germany/Munich/Prod` | closest OU wins over any higher CPU rule |
| Disk `/var/lib/postgresql` | warn 80 / crit 90 | host `db01` | host-level = highest normal priority |

`db01` is unaffected by `/Germany/Munich/Test`'s block_inheritance (different subtree). A host in
`/Germany/Munich/Test` would lose the inherited `/Germany/Munich` 60 s agent check and Root Ping
(blocked), **but keep** the `/Germany` Security-Baseline (enforced pierces block inheritance).

## 13. MVP-Plan in Phasen (Bossman L-series mapping)

- **L1 (done):** OU tree, host groups, orchestration plans/versions/links, `compiled_host_state`,
  compiler, REST. *(varchar path — upgraded to ltree in L3.)*
- **L2 (done):** approval gate, global YOLO-MAN switch, MCP read-only + dry-run + gated write tools.
- **L3 (next):** ltree upgrade + `block_inheritance`; all rule types (thresholds/check-rules,
  notification) bound to OUs with `enforced`/`link_order`; the shared `_resolve_gpo_winner`
  (full GPO precedence); `GET /ou/{id}/objects`; **the GPO tree UI** (this replaces the flat card UI).
- **L4 (done):** transactional outbox + reconciler workers + `agent_config_delivery`/`agent_acks`;
  **controller-initiated PUSH** of desired state to each agent's `POST /api/v1/config/apply` over the
  existing mTLS channel (single firewall rule Bossman → agent; the agent never dials out). Agent side:
  `internal/desiredstate/applier.go` (generation-guarded atomic swap + rollback), write-gated apply
  endpoint, `GET /api/v1/state`.
- **L5:** clusters (`orchestration_clusters`/`_members`, locks, rolling execution) + `postgres_cluster`.
- **L6:** drift detection (`GET /api/v1/state`, controller compare, remediation rules).
- **L7:** schedule/agent-config/discovery/suppression rule types; explain/dry-run/impact UI polish.

## 14. Risiken und Gegenmaßnahmen

- **Reconcile storms** on a high-level rule change (whole subtree recompiles) → batch + debounce
  outbox events per host; hash-skip unchanged.
- **ltree label collisions** (two OU names sanitize to the same segment) → 409 on create; keep the
  human `path` unique separately.
- **Enforced/block-inheritance mis-resolution** → the single shared `_resolve_gpo_winner` with an
  exhaustive test matrix (a–f in the L3 test list).
- **Agent applies a bad config** → generation check + atomic swap + rollback + nack; the agent's
  response is the ack, and a nack flips the delivery to `nacked`/`failed` for backoff-retry.
- **Split-brain between the two databases** (dev vs. compose) → single source of truth per
  environment; migrations gated in CI.

## 15. Offene technische Entscheidungen

- ~~Push transport for L4~~ **(decided):** reuse the controller→agent mTLS channel — Bossman POSTs
  `/api/v1/config/apply` on the agent. No WebSocket/gRPC stream, no agent-facing ingress, single
  firewall rule Bossman → agent.
- Normalize `notification_targets`/`notification_routes` out of `notification_rules` now or when
  routing grows.
- `host_labels` normalized table vs. keep everything in `agents.tags` JSONB (currently both exist;
  label-selector conditions favour the normalized table).
- RBAC enforcement depth (route-level vs. object-level) — the `role` column exists but isn't enforced.
- Whether schedule/agent-config/discovery become full rule types (L7) or stay agent-side defaults.
