# UI information architecture — workspaces, deployments, sequence tree (plan)

> New plan file (2026-08-03). Does NOT replace `docs/ux-workflows.md` (the operator journeys + the
> 2026-07-16 "Author → Run → History" consolidation) or `docs/ui-parity.md` (the parity matrix); it
> supersedes only their **navigation** section and keeps every layout rule from
> `docs/design-philosophy.md` §4 (source list → content → inspector).

## The problem

The nav is a flat list of ~33 entries (20 top-level + 13 under Setup) for 43 routes — one page per
feature. Worse than the length: the things that **belong together are scattered**. Roles
(`/plan-library`), the workflow designer (`/runbooks`), Blueprint (`/blueprint`), Deploy (`/deploy`) and
Provisioning (`/disk-templates`) are all facets of one question — *what do I want to run, and where* —
but the UI presents them as five unrelated pages with no link between them. There is no object that
answers "where is this role deployed?" or "what is deployed on this host?".

## What the reference products do

**Microsoft Configuration Manager (SCCM/MECM)** — the closest mature analogue:

1. **Workspaces, not a flat list.** Four buckets (Assets and Compliance, Software Library, Monitoring,
   Administration); switching a workspace swaps the **node tree** in the left pane, so related functions
   live together and the nav never exceeds a screen.
   ([console overview](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/manage/admin-console),
   [workspaces](https://www.oreilly.com/library/view/system-center-2012/9780132731645/ch08lev1sec3.html))
2. **Result pane = list + detail pane with TABS + filter box.** The detail pane describes the selected
   object; a collection's detail pane has a **Deployments tab**.
   ([console walk-through](https://www.anoopcnair.com/walk-through-sccm-configmgr-console/))
3. **Deployment is a first-class object** joining *content* to a *collection*. You can list the
   deployments targeting a collection and jump from a deployment to its target collection — the
   navigable edge our UI lacks.
   ([console tips](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/manage/admin-console-tips),
   [deployments per collection](https://www.anoopcnair.com/deployments-targeted-to-a-collection-in-sccm/))
4. **Task Sequence = a tree of groups + steps**, reorderable, with per-step conditions.

**Foreman/Katello** does the same with 5 tabs — *Monitor, Hosts, Configure, Infrastructure, Administer*
([docs](https://docs.theforeman.org/3.11/Administering_Project/index-katello.html)). **Uyuni / SUSE
Manager** is strong on patch + OpenSCAP compliance but SUSE-centric
([repo](https://github.com/uyuni-project/uyuni)). **AWX** is job-centric with no real asset model. The
combination usually recommended for a mixed Linux fleet is precisely what we already are: Foreman-style
provisioning + Ansible execution + monitoring — so the gap is the *information architecture*, not features.

**Adaptation rule:** take SCCM's *concepts* (workspaces, deployment-as-object, sequence tree), keep our
*form* — macOS-derived source list → content → inspector, no Windows ribbon (design-philosophy §4).

## Target architecture — five workspaces

A workspace switcher at the top of the source list; picking one swaps the tree below it. Every existing
route keeps working (this is regrouping, not rewriting).

| Workspace | Nodes (existing routes) |
|---|---|
| **Monitor** — what is happening | Fleet Overview `/fleet`, NOC `/noc`, Problems `/problems`, Event Console `/events`, Business services, Capacity, Topology, Security, Compliance, Runs `/runs`, Audit log |
| **Fleet** — the assets | Hosts `/hosts`, **Groups** (HostGroup exists in the DB, no UI yet), Systems `/systems`, Devices `/snmp-devices`, Host placement, OU / Policy `/ou` |
| **Library** — what can be deployed | **Sequences** (new), Roles `/plan-library`, Blueprints `/blueprint`, App Store `/apps`, Modules `/modules`, Checks `/checks`, Config templates, Config codecs, Disk images `/disk-templates` |
| **Deploy** — content × assets | **Deployments** (new), Deploy wizard `/deploy`, Rollouts, Scheduler, Provisioning jobs, Config distribution |
| **Admin** | Users & Access, Notifications, Settings |

Why this fixes the complaint: **Library** is the single home for everything authorable (a role, a
sequence, a blueprint, a template and a module are all "things you can apply"), and **Deploy** holds the
object that binds Library to Fleet.

## Alignment with the object model (`docs/resource-protocol.md`) — non-negotiable

This IA must be **derived from** the Resource/Deployable spine, not invented beside it. A *Resource* is
anything the system can bring to a desired state, and it answers five verbs:

```
schema() -> Schema      # typed fields   → renders the form
observe() -> State      # what IS        → the state shown on the object
plan(desired) -> Diff   # what WOULD change → the preview
apply(dry_run) -> Result# make it so     → records a generation
rollback(generation)    # undo           → forgiveness
```

Three consequences that **correct** the sections below:

**1. Library = the Resource type registry.** Roles, Sequences, Blueprints, Config templates, Modules,
Checks and Disk images are not seven unrelated page types — they are the Resource *implementations*
(`NativeRole`, `RunbookStep`, `ConfigResource`, `TemplateResource`, `DockerContainer`, …). The Library
tree is that registry, and every list row is a Resource answering the same verbs. Adding a tier means
implementing the interface, not adding a page.

**2. ONE canvas, several views — not a third editor.** The protocol is explicit: *"A node is a Resource;
an edge is a dependency/order. A Runbook, an App deploy, a System — all are just graphs of Resource
nodes. One canvas edits [them all]."* So the Sequence tree is **a view over the same Resource graph** the
Blueprint canvas and the runbook designer edit — not a separate tool:

| View | Best for | Same underlying graph |
|---|---|---|
| **Tree** (new) | ordered operational sequences (restore, install) | nodes + order edges |
| **Graph** (Blueprint/cytoscape) | dependency stacks, placement | nodes + dependency edges |
| **Text** (Ansible-task YAML / NestedText) | review, git, diffing | the lossless round-trip |

Switching the view must not change the document. The existing `POST /runbooks/lint` round-trip is the
guarantee.

**3. The inspector is polymorphic — its tabs ARE the verbs.** Do not hand-build a detail pane per page;
build one generic Resource inspector whose tabs come from the interface:

| Tab | Verb | Reuses |
|---|---|---|
| Values | `schema()` | `param-form.component.ts` (schema → form) |
| State | `observe()` | observed-state cache |
| Preview | `plan(desired)` | `state/plan`, `chat-plan-graph` for the diff |
| Deployments / Generations | `apply()` | generations + `blast_radius` |
| Undo | `rollback(generation)` | existing generation restore |

Every object (host, group, role, sequence, blueprint, template) then gets the same tabs for free, which is
also what "all information at a glance" in the design philosophy asks for.

## The missing object: Deployment

In protocol terms a Deployment is **not a new concept**: it is the recorded `apply()` of a Resource onto a
target, and its generations are what `rollback()` undoes. The row is the *binding* (Resource + target +
desired values); the generations are its history.

A `Deployment` row = (Resource ref, target, desired values, schedule/mode, state). It gives the UI its
missing edges:

- Role/Sequence/Blueprint inspector → **Deployments tab**: where is this applied, and is it healthy.
- Host/Group inspector → **Deployments tab**: what is applied here, from which artifact.
- Deploy workspace → one list of everything in flight, filterable, each row linking both ways.
- Runs stay the *execution history*; a Deployment is the *desired-state binding* that produced them.

Targets reuse the existing `scope` vocabulary (`all | host | host_group`), so groups become the
collection equivalent without a new concept.

## The Sequence editor (tree + drag & drop) — a VIEW on the one canvas

The authoring artifact the operator asked for — SCCM's task sequence, in our form. Per the object model
above this is the **tree view of the shared Resource graph**, not a separate editor: every node is a
Resource (answering the five verbs), every edge is order or dependency.

```
Sequence: deploy-webserver
├─ 📁 Prepare                       [when: has_partitions]
│   ├─ ⚙ Task  yoloman.disk_partition
│   └─ ⚙ Task  community.general.lvg
├─ 📁 Install
│   ├─ 🎭 Role  install-nginx
│   └─ 🎭 Role  install-certbot
└─ 📁 Verify
    └─ ✅ Check http_response
```

- **Groups + steps in a tree**, reorderable by drag & drop; a step is any Resource — a Role, a Module
  task, a Check, a Config/Template resource, a container, or a nested Sequence. Per-step `when` / `loop` /
  `register`. A step's form comes from its `schema()`, its badge from `observe()` — so the palette is the
  Resource type registry, and a new Resource type appears in the editor without touching it.
- It maps 1:1 onto the runbook model we already execute: groups are `block` (with `rescue`/`always`),
  steps are module tasks — so a Sequence **serialises to an Ansible-task playbook** via
  `services/ansible_playbook.doc_to_playbook` and runs on the gonja-backed runbook runner unchanged.
- Relationship to the existing editors: the tree is a **view**, so Blueprint's graph view and the Blockly
  designer keep working on the same document; switching view must never change it (guaranteed by the
  `POST /runbooks/lint` round-trip). The tree is simply the right view for ordered operations (it is what
  the restore playbooks look like), the graph for dependency stacks.
- Deployable directly: a Sequence in the Library gets the same **Deploy** action as a Role.

## Slices (each independently shippable + verifiable)

**Slice 1 — workspace nav (UI only, no backend).**
Group the existing routes into the five workspaces with a switcher + per-workspace tree; keep every URL.
*Verify:* every current route reachable in ≤2 clicks; Playwright walk of one route per workspace; nav
never longer than the viewport.

**Slice 2 — the generic Resource inspector (the polymorphic detail pane).**
One inspector component whose tabs are the verbs (Values / State / Preview / Generations / Undo), driven by
a small `ResourceDescriptor` per type; adopt it on the host, role and template pages first.
*Verify:* the same component renders ≥3 different Resource types with no type-specific code in it; the
Values tab is `param-form` fed by `schema()`; the Preview tab shows a real `plan()` diff.

**Slice 3 — Sequence tree view on the shared canvas.** *(pulled ahead of Deployment on the operator's
request — it is the artefact they most want, and slice 2 already supplies its step forms + palette.)*
Tree component with drag & drop over the existing runbook document, palette fed by the Resource type
registry, per-step condition editor, lossless view switching (tree ⇄ graph ⇄ text).
*Verify:* build a sequence in the UI → exported YAML parses via `parse_playbook` and runs with
`run-runbook --dry-run`; reorder persists; a nested group serialises to `block`; switching to the graph view
and back leaves the document byte-identical.

**Slice 4 — Deployment as a first-class object (backend + UI edges).**
Model + migration (Resource ref, target, desired values, state) + generations, `GET/POST
/api/v1/deployments`, the Deploy workspace list. The Deployments tab comes for free from slice 2.
*Verify:* deploy a role to a group → it appears in the Deploy list, on the group, on each member host, and
links back to the role; rollback restores the previous generation; pytest for the API + target expansion.

Order: 1 → 2 → 3 → 4 as numbered above. Two deliberate choices: the polymorphic inspector (2) comes first
because it supplies the step forms and the type palette the tree needs — building the tree first would write
both twice; and the Deployment object (4) goes last because it is backend-only and blocks nothing else (the
sequence editor's "Deploy" button lands with it).

## Explicitly out of scope here

Ribbon/toolbar redesign (we keep macOS-style contextual actions), theming (design-philosophy §"Rastafari"),
and the agentic/planner layer (that is the Agentic-OS discussion, not the IA).
