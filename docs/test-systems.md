# Test Systems — clone-a-prod-system + the rehearsal plane

> Status: PLAN (2026-07-25). Merges two overlooked gaps into one feature:
> the **rehearsal plane** (test a change before prod) and the **system object**
> (a named set of hosts/targets+apps+wiring, above the single host). User
> framing: *"per Klick einen Klon eines Produktivsystems erstellen."*

## Why this is the highest-leverage next step

The whole vision rests on one risky claim: **the AI deploys complex changes
autonomously**. Today we can *preview* a change two ways — `state/plan` (a
syntactic diff) and blast-radius (an impact *estimate*) — but neither actually
**runs** the change to prove it works. That is the difference between a spell-
checker and a rehearsal.

We already ship every piece needed to close it:

| Have | Reused as |
|---|---|
| `export_server_spec` / `materialize_spec` (reproduce) | clone a system's **config** into a sandbox |
| ephemeral tiers — Docker container, k8s namespace | the disposable **sandbox runtime** |
| checks (host/service/snmp) | the **pass/fail gate** on the sandbox |
| `state/apply` generations + rollback | the **change-set** applied to sandbox, then prod |
| `password-depot-api` skill | secrets **by reference**, never in the document |
| topology (`HostEdge`) + eBPF edges | derive the system's **members + wiring** |

Nothing new to invent — this is a **re-wiring** of subsystems that already
exist. It also produces the building block that the platform leap (promote a
whole environment dev→staging→prod) and the governance guardrails both need.

## The three axes of a clone (design decisions, user-confirmed)

A server/system is not just config. Cloning must be explicit about all three:

1. **Config** — cloned from the server-document (`export_server_spec` →
   `materialize_spec` into the sandbox). This is the axis we already own.
2. **Secrets** — **NOT** stored in the document and **NOT** copied from prod.
   They live in the secured password DB (`password-depot-api`); the document
   only holds a **reference/handle**. A test system gets **fresh sandbox
   secrets**, generated and written to the password DB under a test path, then
   referenced — so prod credentials are never reused in a sandbox.
3. **Data** — its own axis, a pluggable **data provisioner**:
   `empty` (schema only) | `seed` (fixtures) | `masked-snapshot` (prod-shaped,
   PII-masked). Start with `empty`/`seed`; `masked-snapshot` is later and needs
   a backup/restore plane.

Being honest about these axes is the point: "reproduce" without this split
silently promises a full clone and delivers a skeleton.

**Clone target tier — DECISION (user, 2026-07-25): cross-tier → container/k8s
is the default.** A native prod app is cloned as a Docker/k8s sandbox: cheap,
instantly disposable, and the ephemeral tiers already exist (docker-test +
minikube). It tests config + health, not 1:1 native OS details — an acceptable
trade for a rehearsal. Same-tier isolated-host clones can come later as a
per-member override if 1:1 originality is ever required.

## The `System` object (the thing above the host)

```
System { id, name, description,
         members: [ SystemMember ],           # the parts
         edges:   [ (from, to, kind) ] }       # the wiring (depends_on, proxies, …)

SystemMember { app_id, target: native|docker|k8s,
               agent_id | cluster_ref,          # where it runs
               role_in_system,                  # e.g. "web", "db", "cache"
               secret_refs: [handle],           # password-DB handles, never values
               data_policy: empty|seed|masked }
```

Bootstrapped from what we already know: topology `HostEdge` + eBPF connection
edges + the apps observed on each host → a *proposed* System the user confirms
and names. Not hand-authored from scratch.

## The rehearsal loop (per proposed change)

```
1. CLONE   prod System ──▶ ephemeral sandbox
             config  = export_server_spec(members) → materialize into sandbox
             secrets = generate fresh → store in password DB (test path) → reference
             data    = provisioner(empty|seed|masked)
2. APPLY   the proposed change-set to the sandbox (state/apply, dry_run=false)
3. TEST    run each member app's checks against the sandbox
4. REPORT  pass/fail + the observed diff (what actually changed vs predicted)
5. PROMOTE on green → apply the SAME change-set to prod as ONE atomic unit
6. TEARDOWN the sandbox (disposable by construction)
```

Step 5 is where gap #5 (atomic cross-tier rollback) lands: the change-set is
the rollback boundary spanning native+docker+k8s, promoted or rolled back as a
unit — not three independent generations.

## Blocks (each independently testable, one commit each, no push)

**Block 1 — `System` model + read-model API.** `db/models.py` System +
SystemMember; `api/systems.py` GET/POST /systems, GET /systems/{id};
`services/system_discover.py` proposes a System from topology+observed apps.
*Verify:* propose a System for docker-test, confirm members = its observed apps.

**Block 2 — clone (config axis).** `services/system_clone.py`: for each member,
`export_server_spec` → `materialize_spec` into a sandbox target (ephemeral
docker/k8s), dry_run default. *Verify:* clone a one-member System → sandbox
gets the same config resources (changed_count matches), dry-run shows the plan.

**Block 3 — secrets by reference.** Integrate `password-depot-api`: on clone,
generate fresh sandbox secrets, write under a test path, store only the handle
on the SystemMember. Prod secret VALUES never enter the document or the sandbox
spec. *Verify:* cloned member references a *new* handle; prod handle untouched;
no secret value in the exported spec.

**Block 4 — data provisioner.** Pluggable `empty|seed`; `masked-snapshot`
stubbed for later. *Verify:* clone with `seed` lands the fixture; `empty` lands
none.

**Block 5 — rehearsal loop.** `services/rehearsal.py`: clone → apply change-set
to sandbox → run members' checks → pass/fail + diff report. *Verify:* a change
that passes checks reports green; a deliberately broken change reports red with
the failing check.

**Block 6 — promote as an atomic change-set.** Apply the rehearsed change-set to
prod as one unit with a single rollback boundary across tiers; teardown sandbox.
*Verify:* green rehearsal → promote → prod at new generation; forced failure
mid-promote rolls the whole set back.

**Block 7 — UI + MCP.** "Clone to test system" button (from a host/System view)
+ a rehearsal-result panel (pass/fail, diff, Promote/Discard). MCP tools
(`system_propose`, `system_create`, `system_clone`, `system_rehearse`,
`system_promote`) so the **AI runs rehearsals autonomously** before any prod
deploy — the same loop, one authoring model.

*The tool names above are the ones the code actually exports.* This plan first
called two of them `rehearse_change`/`promote_change`, and a review looking for
those names concluded the block was unfinished when it was not: one thing under
two names is the identity defect this project audits for everywhere else, and a
plan is not exempt from it. *Verify:* Playwright clone→rehearse→promote against
docker-test; MCP path does the same.

**Block 8 — docs.** This file + `deploy/README*.md` + `CODE_CARD.md`.

## Explicitly out of scope here (routed elsewhere, per user)

- **Forecast / future-tense document** (gap #6) → the already-planned forecast
  feature: `predicted_problems` as first-class document fields (cert expiry, CVE
  aging, capacity), so the AI reasons over "what breaks next" like any fact.
- **Self-monitoring the control plane** (gap #7) → continue the thread started
  with the poller instance: Bossman + agents + LLM endpoints as apps in the
  catalog, monitored by their own checks. Carry through consistently.
- **Provenance from the kernel** (gap #1) → separate quick win: wire eBPF file
  write-events → drift attribution (who/when), so the audit trail writes itself.

## End-to-end success

One click on a prod System produces a sandbox with cloned config, fresh sandbox
secrets (in the password DB, referenced not copied), and seed data; a proposed
change is applied there, the apps' own checks gate it, and only on green does it
promote to prod as one atomic, rollback-able change-set — and the AI can drive
the exact same loop via MCP.
