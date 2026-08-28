# The App model — one abstraction, three runtimes

**Vision.** A server is fully **API-manageable** — the server *is* a JSON
document you read/plan/apply/roll back (see [design-philosophy.md](design-philosophy.md)
and the server-as-document north-star). The next level up: the unit of
management is no longer "a config file on a host" but an **App** — a deployable,
value-configurable, versioned, roll-back-able thing. Docker is a *sandboxed* app
system; Kubernetes is an *orchestrated* one; a native package+config is the
*bare* one. This doc defines the single **App abstraction** that spans all three
so the UI, API, and lifecycle are identical regardless of runtime.

## The one model

Everything reduces to the same grammar we already run for config:

```
values  →  artifact(values)  →  apply to a target  →  generation (+ rollback)
```

An **App** is:

```jsonc
{
  "id": "nginx",
  "label": "NGINX Web Server",
  "category": "web",
  "values_schema": { … },            // one JSON schema → the param-form (dropdowns, file-picker, …)
  "targets": {                        // which runtimes this app supports, + the artifact per runtime
    "native": { "role": "nginx", "template": "nginx" },      // package + Class-B config template
    "docker": { "image": "nginx:1.27", "compose_template": "nginx-compose" },
    "k8s":    { "chart": "oci://…/nginx", "values_schema_ref": "chart" }
  }
}
```

A **Target** is *where* an app instance runs, one of three tiers by
isolation + scale:

| Target | Isolation / scale | Artifact | "Deploy" = | "Configure" = | Rollback = |
|---|---|---|---|---|---|
| **native** | none — config on the OS | package + Class-B template | install package + render config | values → `template_render` via `state/apply` | `state` generations |
| **docker** | sandboxed, 1 host | image + compose/env | `docker compose up` / run | values → compose/env, re-up | previous compose generation |
| **k8s** | orchestrated, N nodes | Helm chart | `helm upgrade --install` | values → `helm upgrade` | `helm rollback` |

Same four verbs — **deploy · configure · upgrade · rollback** — same
values-form, same generations semantics; only the runtime differs.

## What already exists (map onto the model)

The **native** tier is essentially built — the App layer is a thin unification
over it, not new machinery:

- **Catalog:** `GET /api/v1/package-catalog` (`configs/package_catalog.json`,
  built by `build_package_catalog.py`; roles carry `label/category/icon/
  families/validate_cmd/template`). → becomes the App catalog.
- **Values schema + form:** each app's `configs/config_templates/<name>/schema.json`
  → `ParamForm` (enum dropdowns, bool toggles, list tables, cert/key **file-picker**).
- **Deploy:** `POST /api/v1/runbooks/role/compile` (role → runbook) +
  `POST /api/v1/deployments/run` (fan out to `targets`) — installs the package
  and applies config.
- **Configure + versioning + rollback:** `POST /api/v1/agents/{id}/state/apply`
  (`type:"config"|"template_render"`), `state/generations`, `state/rollback`.
  The web-server snapins (nginx/apache/haproxy/caddy/traefik) are **native apps**
  today — value-form → template_render → apply → validate → reload.

Gap: there is **no `App` object or `/apps` API yet**, and no **docker** or
**k8s** target. Those are what this model adds.

## Proposed API (thin layer, wraps what exists)

```
GET  /api/v1/apps                         # unified catalog (native+docker+k8s capable)
GET  /api/v1/apps/{id}                     # values_schema + supported targets + artifacts
POST /api/v1/apps/{id}/plan                # values + target → render/preview (dry-run, blast radius)
POST /api/v1/apps/{id}/deploy              # values + target(host|docker|cluster) → install/upgrade
GET  /api/v1/apps/instances                # deployed instances (any tier) + version/health
POST /api/v1/apps/instances/{iid}/rollback # previous generation / helm revision
```

Internally each verb dispatches to the tier's existing mechanism (native →
runbook/state; docker → agent `docker`/compose; k8s → Helm). One request shape,
one response shape (`{plan:{changes,changed_count}, generation}`), whatever the
runtime — so the UI never branches on tier except to pick the target.

## UI: one "Apps" / app-store screen

Browse the catalog → pick an app → **pick a target** (this host native · this
host Docker · a Kubernetes cluster) → **configure by values-form** (the same
`ParamForm`) → Preview (render/plan) → Deploy → see instances with version +
Rollback. The per-host Management snapins remain the "native, already-installed"
detail view; the app-store is the fleet-wide deploy surface.

## Increments (no big-bang)

1. **Define `App` + `/apps` catalog** as a read-model over `package-catalog`
   (native only) — no behavior change, just the unified shape + `targets.native`.
2. **Docker target:** an agent `docker`/compose action + a `*-compose` template
   per app; deploy/configure/rollback by values (the sandboxed tier — smallest
   new step, immediately useful).
3. **K8s target:** the Helm plan ([Kubernetes support plan]) — chart
   `values.schema.json` → the same form → `helm upgrade`/`rollback`.
4. **Unify deploy UI** into the app-store with the target picker.

## Where the agentic layer fits

This App/API substrate is the **object** an agent acts on, not the agent itself.
Governance/reasoning (audit trail, approval/guardrail policies, closed-loop
remediation, NL-intent→plan — see the agentic-OS roadmap) plug in *on top* of
`/apps` + `state` later. Substrate first.
