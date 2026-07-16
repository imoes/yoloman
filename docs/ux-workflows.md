# Workflow walkthrough — the core operator journeys

A logical pass over every core workflow, the macOS/Windows bar: each task has
one obvious place, the next step is always visible, and the same concept is
named the same everywhere. ✅ = coherent now, ⚠️ = friction (fix listed).

## Navigation (information architecture)

Consolidated to roles-centric automation (2026-07-16):

- **Author → Run → History**: **Roles** (the library/tree + editor, was "Plan
  library") → **Deploy** (drag roles into a run, per-role params, fan out to
  hosts/groups) → **Runs** (unified history). Dropped the redundant
  **Runbooks** + **Plans** nav entries (we author roles, not playbooks/tasks).
- Monitoring stays top-level: Fleet Overview, Problems, Topology, Security,
  Host placement.
- **Setup** groups config/admin: Hosts, Notifications, OU/Policy, Modules,
  Checks, Config templates, Users & Access, Settings.

## 1 · Add a host  ✅

Path: **Hosts → Add host** → dialog with two methods:
1. copy the self-configuring `agentic-mcpd register` command to run on the
   host (zero-touch: token + TLS cert + enroll + restart all automatic);
2. SSH deploy (if a deploy identity is configured): paste hostnames, Bossman
   installs + enrolls each.
Was previously only in Settings — now surfaced where you'd look for it.

## 2 · Assign checks to a host  ⚠️

Path: **Host → Checks tab** → "Add a check to this host" / "Auto-discover
checks" / "Variables…"; or scope-wide via **OU/Policy → Assign Check** on the
host's OU or a group.

⚠️ **F-4 — two notions of "check" with no cross-link.** The Checks tab's
"Effective checks" lists assigned Starlark checks (0 on docker-test), while the
**Services** tab shows 14 services (agent builtins CPU/mem/disk + monitoring
check_rules). A user sees "14 services" and "No checks apply" at once and can't
tell why. Target: the Checks tab should also surface the monitoring
services/thresholds that apply (or clearly separate "monitoring services" from
"assigned checks"), and each service should link to the rule/threshold that
produced it.

## 3 · Create a policy for a host  ✅

Path: **Host → Configuration tab** — the gpedit editor (Miller columns:
category → file → settings). Set a config value with scope **this host**;
thresholds live under the Monitoring category. Rollback-able generations,
per-key drift. Coherent and self-contained.

## 4 · Create a policy for an OU  ✅

Path: **OU/Policy → select an OU** → the full gpedit editor (Miller columns) +
right-click actions (Config setting…, Threshold…, Notification…, Assign
Check…, Host Group…). Policies show as objects under the OU and can be
**dragged onto another OU to move/re-scope** them.

## 5 · Create a policy for a group  ⚠️

Path: **OU/Policy → right-click a host group** → Config setting… / Threshold…
/ Assign Check… (the focused dialogs).

⚠️ Groups get the focused *dialogs* but not the full gpedit **Miller-column
editor** that OU nodes get (that panel renders only for `sel.kind === 'ou'`).
Target: show the same gpedit editor when a host group is selected, scoped to
the group (the backend already supports `host_group_id` on config policies +
the editor is scope-agnostic — it just needs a group entry point).

## Follow-ups (ranked)

1. **F-4 check/service unification** on the host (biggest confusion).
2. **Group gpedit** — give host groups the same Miller-column editor as OUs.
3. **F-5** Modules page "checkmk 0/1444" vs the Checks catalog count.
4. Deploy: allow reordering roles in a Run; persist a Run as a reusable set.
