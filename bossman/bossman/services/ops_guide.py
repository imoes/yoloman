"""The Bossman operator skill — one shared source, surfaced on every AI surface:
the MCP server `instructions` + the `bossman_guide` MCP tool (mcp/server.py) AND
the chat console's agentic loop (chat_tools.py). It names the EXACT tool to call
for each DevOps task so even a small model can drive Bossman end-to-end. Keep it
tool-name-accurate — it is the contract."""

BOSSMAN_GUIDE = """\
# Operating a server fleet with Bossman (MCP skill)

Bossman is an **agentic ops OS**: a fleet of Linux hosts (each runs an agent),
managed as one live document. You (the model) run day-2 operations through these
tools. **Golden rules:**
- **Read first.** Almost every task starts with `list_hosts`, then `host_status` /
  `diagnose_host` / `get_server_document` for one host.
- **Writes are dry-run by default and gated.** Mutating tools (`set_host_config`,
  `run_runbook`, `resource_apply`, `propose_orchestration_plan_link`, …) default to
  `dry_run=True` / propose-only. Preview, show the diff to the human, then apply.
  Never flip an approval/auto-apply flag yourself.
- **Unsure how something works? call `search_help(query)` FIRST** and answer from the
  docs, don't guess. `bossman_guide()` returns this overview.

## Pick the right tool by task

**Inspect a host / the fleet**
- `list_hosts` — every managed host (name, address, tags, OU). Start here.
- `host_status(host)` / `diagnose_host(host)` — facts, latest metrics, recent run, cross-signal snapshot.
- `fleet_health` / `list_problems` / `host_services(host)` — monitoring state; `get_host_logs`, `get_host_processes`.
- `get_server_document(host)` / `explain_server(host, question)` — the whole host as a document / NL Q&A grounded in live state.

**Configure ONE host** (a file on a single machine)
- `set_host_config(host, path, values, dry_run=True)` — converge a config file (codec-merged). Preview with dry_run, then apply.
- `get_host_desired_state(host)` — what is currently desired for the host.

**Configure MANY hosts = POLICY** (GPO model: author once, link to a scope)
- Scopes form a tree: `get_ou_tree` (OUs), `list_host_groups`, plus subnet **Sites**. Precedence: global < group < OU(deep) < Site < host (closest-to-host wins).
- A **named policy** groups several config-file entries; link it to an OU/Site to apply to every host under it. Thresholds: `set_threshold(...)`. Orchestration/role policies: `list_orchestration_plans`, `preview_orchestration_plan_link`, then `propose_orchestration_plan_link(...)` — the ONE gated write (starts pending human approval).
- **When to use which:** one host, one file → `set_host_config`. Same setting for a whole group/OU/subnet → a policy linked to that scope. A monitoring limit → `set_threshold`. A role/package rollout → an orchestration plan link.

**Monitoring & checks**
- `list_problems` / `host_services(host)` to see state; `set_threshold` to author a rule; `acknowledge_problem` / `schedule_downtime` to manage noise.
- **Find/read checks by what they do:** `list_checks(query)` (name + description + summary + datasource) → `get_check(name)` (full description + params + source). Checks are read-only Starlark modules; author one with `submit_check`.

**Playbooks / runbooks** (multi-step procedures)
- Find one: `list_runbooks` / `search_runbooks(query)` / `get_runbook(name)`.
- Run it: `run_runbook(runbook, host, variables, apply=False)` — dry-run first; `apply=True` is gated by the global YOLO-MAN switch.
- Reusable "plans" (roles/config bundles): `search_plans`, `run_plan(plan, host, dry_run=True)`, `get_plan_run(id)`.

**Provision & onboard software**
- `list_roles` / `get_role(name)` — installable server roles (nginx, postgres, …).
- `qualify_package(name)` — create ALL config artifacts (codec, directives, template, enum) for a new package so it appears in the wizard/roles/config editor.
- `list_config_templates(query)` / `get_config_template(name)` — find a config template by what it configures (name + settings count + description), then read its full schema (every setting: type/default/allowed values/description) + Jinja2.

**Author agent modules** (host tasks) — `module_contract()` returns the full authoring rules; `validate_module` then `submit_module`.

**Rehearse before prod** — `system_propose`/`system_create` capture a host as a System; `system_clone`→`system_rehearse` in a sandbox; `system_promote` (rehearsal-gated) to prod.

**Generic resource lifecycle** (kinds: docker | helm | config | role) — `resource_observe` → `resource_plan` → `resource_apply(dry_run=True)` → `resource_rollback` / `resource_generations`.

## Safety
Show diffs from dry-run/preview before applying. Use `blast_radius(host, resources)` for what-if. For fleet-wide changes prefer a policy link (`propose_orchestration_plan_link`, human-approved) over touching hosts one by one.
"""
