# etcd vs. Postgres for Bossman's key-values — analysis & recommendation

> Decision note. Answers three questions: (1) why the key-value data lives in
> Postgres and not etcd, (2) whether migrating the key-values to etcd is worth
> it, and (3) what we would gain by using the *full* power of etcd. Grounded in
> the actual schema (`bossman/bossman/db/models.py`), not generic comparison.

## TL;DR

**Keep Postgres as the source of truth. Do not migrate the key-values to etcd.**
Our "key-values" are not a flat KV workload — they are *scoped, versioned,
relational documents* (GPO-style precedence over an `ltree` OU tree, per-stage
versioning, audit trail, foreign keys). etcd is a flat, size-capped
(~8 GB), consensus-replicated KV store built for cluster coordination, not for
querying documents by scope, joining them, or keeping unbounded history. The
few things etcd is genuinely great at — **watch** (push on change) and
**leases** (TTL liveness) — we already have, DB-native: config changes push to
agents through a **transactional-outbox → reconciler → delivery-queue** pipeline
with acks (`controller_outbox` → `services/reconciler.py` → `agent_config_delivery`
/ `agent_acks`), and reachability is tracked via `connection_events` + the 60 s
poller. Apply is a *real* push, not a poll: it writes desired state and the
outbox event in one transaction, and the reconciler delivers to reachable hosts
(returning `applied_hosts`/`skipped_hosts`). No capability is missing here — at
most a latency optimisation (wake the reconciler via `LISTEN/NOTIFY` instead of a
short poll loop). A hybrid where etcd is added *only* as a change-notification
bus is possible but pointless at our scale.

## 1. What "the key-values" actually are here

The phrase covers a handful of tables, and every one of them carries structure
that a plain KV store does not model:

| Data | Table(s) | Shape | Why it isn't flat KV |
|---|---|---|---|
| Config policies (gpedit) | `config_policies`, `config_policy_sets` | `(scope, path) → {key: value}` JSON doc | Scoped to OU/group/site/host; **precedence** `global < group < OU(root→deep) < Site < host`; unique `(scope_ou_id, path)`; grouped into named sets |
| Scope variables | `scope_vars` | `(scope) → {key: value}` | Same precedence tree; referenced by templates |
| Compiled desired state | `compiled_host_state` | per-host resolved doc | Product of a **compile/merge** over the tree — a *derived* view |
| Observed state cache | `agent_observed_state` | per-host snapshot | Poller-refreshed (15 min), served instead of live host pass-through |
| Per-host resources | `host_config_resources` | resource rows | Joined to hosts, capabilities, generations |
| Versioned generations | `resource_generation`, `orchestration_plan_versions` | history | Keep-last-N, rollback |
| Global settings | `system_settings` | `key → value` | The *only* genuinely flat KV here |

Only `system_settings` is a real flat KV. Everything else is a **document
addressed by a position in a tree**, resolved through inheritance rules, and
often versioned and audited (`audit_log`, `policy_events`). That is a
relational/document workload, not a coordination-KV workload.

## 2. Why we did not use etcd

1. **The core operation is scoped resolution, not `GET key`.** Applying policy
   to a host means "walk the OU ancestry, overlay group/site/host, resolve
   precedence, merge the docs". In Postgres this is one `ltree` query + a merge.
   In etcd it would be N range reads plus all merge/precedence logic
   reimplemented in the app, with no server-side query.
2. **etcd is size- and value-capped.** Default DB quota is ~2 GB (max ~8 GB),
   and each value is capped at 1.5 MB by default. Our metrics alone
   (`metrics_raw`, `metric_series` in TimescaleDB) dwarf that, and config
   history is unbounded-by-policy (we prune to 30 generations by *choice*, not
   because the store forces it). etcd is deliberately small; it is a coordination
   store, not a database.
3. **We already have one database, on purpose.** [single-database]: one
   Postgres/TimescaleDB instance is the source of truth. Adding etcd means a
   second stateful system to run, back up, secure (mTLS/RBAC), upgrade, and keep
   consistent with Postgres — for data that Postgres already models better.
4. **Transactions across related rows.** Linking a policy, writing an audit
   row, bumping a generation, and emitting an outbox event happen in *one* SQL
   transaction. etcd has mini-transactions (`If/Then/Else` on a small key set)
   but no multi-table ACID; we would lose atomicity or bolt a saga on top.
5. **Rich queries and joins.** The UI and MCP ask relational questions ("which
   hosts get this policy", "all thresholds for this metric", RSoP reports,
   compliance joins). SQL answers these directly; etcd cannot join or filter
   server-side.
6. **History, audit, and versioning are first-class.** `audit_log`,
   `resource_generation`, `orchestration_plan_versions`, `policy_events`. etcd's
   MVCC keeps revisions only until the next **compaction** — it is not an audit
   trail and is explicitly not meant to be mined for history.

## 3. Is it worth migrating the key-values to etcd?

**No.** Summary of the trade:

| Dimension | Postgres (today) | etcd | Verdict |
|---|---|---|---|
| Scoped/precedence resolution | `ltree` + merge, server-side | app-side range reads + reimplement merge | Postgres |
| Query / join / report (RSoP, compliance) | native SQL | none | Postgres |
| Multi-object atomic change | one ACID txn | limited mini-txn | Postgres |
| History / audit / versioning | first-class tables | revisions until compaction | Postgres |
| Size (config + metrics + history) | unbounded (Timescale) | ~2–8 GB cap, 1.5 MB/value | Postgres |
| Change notification (push) | `LISTEN/NOTIFY`, outbox | **watch (native)** | etcd (marginal) |
| Liveness / TTL | heartbeat column, `connection_events` | **leases (native)** | etcd (marginal) |
| Ops burden | one system already run | +1 stateful cluster | Postgres |
| Horizontal read scale / linearizable reads across DCs | single node (+replicas) | **raft, multi-node** | etcd (only if we go multi-DC control plane) |

etcd wins two rows — **watch** and **leases** — and a third (**linearizable
multi-node consensus**) that only matters if the *control plane itself* becomes
multi-datacenter and needs leader election. None of those outweigh losing
server-side resolution, joins, ACID, and unbounded history for the config data.

## 4. What we would gain by using the *full* power of etcd

Listing the real capabilities so the trade is honest — and mapping each to how
we already cover it (see [agentic-os-roadmap], [project-pxe-bootstrap]):

- **Watch (change streams).** Agents/UI subscribe to a key prefix and are pushed
  every change with its revision — the natural backbone for *closed-loop*
  desired-state convergence ("config changed → converge now" instead of poll).
  *We already do closed-loop push*: Apply writes desired state **and** a
  `controller_outbox` event in one transaction; the reconciler drains the outbox,
  recompiles affected hosts, and delivers to reachable agents with acks
  (`agent_config_delivery` / `agent_acks`). The reconciler wakes on a short poll
  of the outbox; `LISTEN/NOTIFY` would make that wake instant — a latency tweak,
  not a new capability. Watch adds nothing we lack.
- **Leases + keepalive.** A host holds a TTL lease; miss the keepalive and its
  keys vanish → instant, self-cleaning liveness and "ephemeral" registration.
  Elegant for agent liveness and for PXE one-shot registration that should
  expire. *We already track liveness* with `connection_events` + the 60 s poller
  + delivery status (`nacked`/`failed`); a lease model is cleaner in theory but
  buys nothing over a `last_seen`/TTL column + sweeper.
- **MVCC revisions + compare-and-swap.** Every write gets a global revision;
  `txn(If revision==R).Then(put)` gives optimistic concurrency. Useful for
  conflict-free concurrent edits. *We cover it* with row versions/`updated_at`
  and the new draft-mode staging (review-before-apply) at the UI layer.
- **Leader election / distributed locks.** Elect one active controller, hold a
  singleton lock for a rollout. Only relevant if we run **multiple** Bossman
  controllers for HA. Today there is one control plane; when HA is on the table,
  Postgres advisory locks or a small etcd/Consul *for coordination only* is the
  right tool — not for the config data.
- **Linearizable, replicated reads across nodes.** Strong reads from any member.
  Matters for a geo-distributed control plane; irrelevant for a single instance.

The theme: etcd's superpowers are **coordination** (watch/leases/election), and
those map to our *transport/liveness* layer, which is already solved — not to
the *config data model*, which Postgres models far better.

## 5. Recommendation

1. **Do not migrate config/variables/state to etcd.** They are scoped, versioned,
   joined, audited documents — a Postgres strength and an etcd anti-pattern.
2. **Change-push and liveness are already solved — no gap to fill.** Apply is a
   real push (outbox → reconciler → `agent_config_delivery` with acks); liveness
   comes from `connection_events` + the 60 s poller + delivery status. The only
   *optional* tweak is waking the reconciler via **`LISTEN/NOTIFY`** instead of a
   short poll, to shave seconds of propagation latency — nice-to-have, still one
   system, and not a reason to add etcd.
3. **Reserve etcd (or Consul) for one future case only: HA control-plane
   coordination** — leader election / singleton rollout locks *if and when* we
   run multiple controllers. Even then it holds *coordination keys*, never the
   config data. Until then, Postgres advisory locks suffice.
4. Revisit only if a hard requirement appears that Postgres genuinely can't meet:
   a **multi-datacenter, multi-writer control plane** needing linearizable
   consensus. That is an architecture change, not a KV swap.

## Related

- [single-database] — one Postgres/TimescaleDB source of truth (dev = the test system)
- [agentic-os-roadmap] — closed-loop remediation & governance gaps (where watch/leases would land)
- [project-config-model-consolidation] — the one FieldSpec + versioned Stage pipeline the config data feeds
- [project-server-as-document] — the server-as-one-document north star the config data serves
