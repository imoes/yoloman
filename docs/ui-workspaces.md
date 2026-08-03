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

## The missing object: Deployment

A `Deployment` row = (library artifact, target, schedule/mode, state). It gives the UI its missing edges:

- Role/Sequence/Blueprint inspector → **Deployments tab**: where is this applied, and is it healthy.
- Host/Group inspector → **Deployments tab**: what is applied here, from which artifact.
- Deploy workspace → one list of everything in flight, filterable, each row linking both ways.
- Runs stay the *execution history*; a Deployment is the *desired-state binding* that produced them.

Targets reuse the existing `scope` vocabulary (`all | host | host_group`), so groups become the
collection equivalent without a new concept.

## The Sequence editor (tree + drag & drop)

The authoring artifact the operator asked for — SCCM's task sequence, in our form:

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

- **Groups + steps in a tree**, reorderable by drag & drop; a step is a Role, a Module task, a Check, or
  a nested Sequence. Per-step `when` / `loop` / `register`.
- It maps 1:1 onto the runbook model we already execute: groups are `block` (with `rescue`/`always`),
  steps are module tasks — so a Sequence **serialises to an Ansible-task playbook** via
  `services/ansible_playbook.doc_to_playbook` and runs on the gonja-backed runbook runner unchanged.
- Relationship to the Blockly designer (`/runbooks`): Blockly stays for branching logic; the tree is the
  better editor for ordered operational sequences (and is what the restore playbooks look like).
- Deployable directly: a Sequence in the Library gets the same **Deploy** action as a Role.

## Slices (each independently shippable + verifiable)

**Slice 1 — workspace nav (UI only, no backend).**
Group the existing routes into the five workspaces with a switcher + per-workspace tree; keep every URL.
*Verify:* every current route reachable in ≤2 clicks; Playwright walk of one route per workspace; nav
never longer than the viewport.

**Slice 2 — Deployment as a first-class object (backend + UI edges).**
Model + migration, `GET/POST /api/v1/deployments`, the Deploy workspace list, and the **Deployments tab**
on the host, group, role and sequence inspectors.
*Verify:* deploy a role to a group → it appears in the Deploy list, on the group, on each member host,
and links back to the role; pytest for the API + the target expansion.

**Slice 3 — Sequence tree editor.**
Tree component with drag & drop, step palette (roles / modules / checks), per-step condition editor,
round-trip to the canonical runbook doc and to Ansible-task YAML.
*Verify:* build a sequence in the UI → exported YAML parses via `parse_playbook` and runs with
`run-runbook --dry-run`; reorder persists; a nested group serialises to `block`.

Recommended order: 1 → 2 → 3 (a sequence wants a Deploy action to be useful, and Deploy needs the object
from slice 2).

## Explicitly out of scope here

Ribbon/toolbar redesign (we keep macOS-style contextual actions), theming (design-philosophy §"Rastafari"),
and the agentic/planner layer (that is the Agentic-OS discussion, not the IA).
