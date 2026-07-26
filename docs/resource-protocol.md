# Resource / Deployable — one object, three faces, one canvas

> Status: CONCEPT (2026-07-26). The OOP spine that makes the system *simple*:
> every manageable thing is one kind of object with one small interface, it
> serialises to the server-document, and it draws itself as a node in the
> Workflow Designer. Measured against `docs/design-philosophy.md` (macOS).

## The core idea (keep it small)

Today the lifecycle logic is scattered — `internal/state` knows config +
template_render, Docker lives in `docker_app.py`, k8s in `helm_app.py`, systems
in `system_*`. Each reinvents observe / plan / apply / rollback. That is the
source of every "docker has no generations", "rehearse is docker-only",
"cross-tier is special-cased" gap.

**One interface fixes it.** A *Resource* (a.k.a. Deployable) is anything the
system can bring to a desired state:

```
class Resource(Protocol):        # the whole contract — four verbs
    def schema()   -> Schema     # its typed fields  → renders a form
    def observe()  -> State      # what IS            → shown on the node
    def plan(desired) -> Diff    # what WOULD change  → the preview
    def apply(dry_run) -> Result # make it so         → records a generation
    def rollback(generation)     # undo               → forgiveness
```

Implementations: `ConfigResource`, `TemplateResource`, `DockerContainer`,
`HelmRelease`, `NativeRole`, `RunbookStep`. Adding a tier = implementing the
interface, **not** editing every orchestrator. That is the entire OOP payoff
(polymorphism + encapsulation) and nothing more — deliberately minimal.

## Three faces of the same object

A Resource is simultaneously:

1. **A code object** — the polymorphic handler above (the *verbs* / behaviour).
2. **A document node** — a serialisable JSON record in the server-document
   (the *nouns* / state): `{type, id, values, …}`. Diffable, versioned,
   API- and AI-manageable. This is the moat; we never trade it away.
3. **A visual node** — a box on the Workflow Designer canvas that renders its
   own form (from `schema()`), its own preview (from `plan()`), its own health,
   and carries one apply/rollback action.

> **Objects are the verbs; documents are the nouns.** We OOP the behaviour and
> keep the state declarative — so the canvas, the API, and the AI all speak the
> same four verbs over the same serialisable graph.

## Binding to the Workflow Designer (the one canvas)

We already ship the pieces — this generalises them into one editor:

| Piece (exists) | Becomes |
|---|---|
| `sequential-workflow-designer` (runbook editor) | the node canvas for ANY Resource graph |
| `param-form.component.ts` (schema → form) | how a node renders `schema()` |
| `chat-plan-graph` (cytoscape DAG) | how a rendered plan (`plan()`) is drawn |
| `POST /runbooks/lint` (text ↔ JSON ↔ visual) | the lossless text/visual/document round-trip |
| `state/plan` · `state/apply` · generations · `blast_radius` | a node's preview / apply / undo / impact |

**A node is a Resource; an edge is a dependency/order.** A Runbook, an App
deploy, a System — all are just *graphs of Resource nodes*. One canvas edits the
runbook, the config set, the container, the Helm release, and the whole System —
because every node answers the same four verbs and hands the canvas its schema
and its render.

Concretely, each node type registers a tiny descriptor:
```
NodeType {
  kind: "docker_container" | "config" | "helm_release" | "role" | …
  icon, label
  form(schema)      // param-form
  preview(plan)     // diff text / resource graph
  status(observe)   // dot + value (healthy / drift / crit)
}
```
The canvas is generic; the *object* supplies its face. New tier = new descriptor
+ new Resource impl. Nothing else changes.

## macOS usability, baked into the object model

The three rules the user named, realised by the interface itself (not bolted on):

### 1. It configures itself
- **Pre-populated, never blank.** The canvas is seeded from live state:
  `config_discover` + `inspect_containers` + `helm list` + `propose_system`
  already produce the node graph. `schema()`'s defaults (sample.json / chart
  values / codec inference) fill the forms. The user opens a *finished-looking*
  system and edits, rather than assembling from nothing.
- **Enums as choices, not free text** — the ADMX/value catalogs + chart schema
  turn fields into dropdowns (param-form already does this).

### 2. All information at a glance
- Each node shows, inline: **observe()** (current value / health dot),
  **plan()** (the diff badge — "will change"), the owning check's warn/crit, and
  **blast-radius** (who depends on it). One screen = the whole picture:
  what it is, what will change, what it affects. No drilling to find "why".
- Source-list → canvas → inspector (Finder layout, per design-philosophy §4):
  pick a node, its facets fill the right inspector.

### 3. The user only decides
- The system has already computed the plan **and rehearsed it** (test-systems
  Block 5). The node presents a result and **one primary action** (Deploy /
  Approve) — green, unambiguous (design-philosophy §6). Everything else is
  progressive disclosure (Advanced hidden).
- **Forgiveness** (design-philosophy §7): dry-run + rehearsal before apply,
  generations + rollback after. Every decision is reversible, so deciding is
  safe.

## Resource types = the whole system, unified

| Resource | schema() | observe() | apply() |
|---|---|---|---|
| ConfigResource | codec's directive catalog | read file via codec | write via codec → generation |
| TemplateResource | template's schema.json | rendered file hash | gonja render → write |
| DockerContainer | image/ports/env/volumes | `docker inspect` | rm+run (idempotent) |
| HelmRelease | chart values (typed form) | `helm status` | `helm upgrade --install` |
| NativeRole | role input mask | services + config state | runbook run → state/apply |
| RunbookStep | module param schema | register/facts | `module.Run(...)` |

A **Runbook** = an ordered graph of RunbookStep + Resource nodes. A **System** =
a graph of Resource nodes across tiers + dependency edges. Same object model,
same canvas, same four verbs — *that* is the simple system.

## Incremental path (no big-bang)

1. **Define the interface** (`Resource`) + a node-descriptor registry.
2. **Wire one type end-to-end**: `DockerContainer` implements observe/plan/apply/
   rollback → gives Docker its own generations (closes a flagged gap) and a
   canvas node.
3. **Generalise the designer**: node descriptors drive the canvas; the runbook
   editor becomes one consumer of it.
4. Fold in `config` / `template_render` / `helm_release` / `role` one at a time.
5. The System view (test-systems) and the App-Store deploy become canvases over
   the same nodes.

Each step is independently testable and shippable, and each removes a special
case. The end state: **one small interface, one canvas, one document** — a
system that configures itself, shows everything at a glance, and asks the user
only to decide.
