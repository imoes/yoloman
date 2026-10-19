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
- **Unsure what an option, directive or config file does?** `man_search(host, query=…)` then `man_search(host, page=…, grep=…)` — the manual pages installed on that host document exactly its versions; read them before changing a setting you would otherwise guess.
- `list_hosts` — every managed host (name, address, tags, OU). Start here.
- `fleet_search(query)` — **search the WHOLE fleet's desired state in one call** (config keys/values, variables, host tags, Ansible facts, applied checks/roles/thresholds). Fastest way to answer "which hosts have X?". Plain substring, or `key=value` (path contains key AND value contains value): `os.family=Debian`, `timezone=Europe`, `role=web`, `config./etc/ntp.conf`.
- `host_status(host)` / `diagnose_host(host)` — facts, latest metrics, recent run, cross-signal snapshot.
- **A service does not start / does not run?** `diagnose_service(host, name)` — the host's own explainable diagnosis (Windows service or systemd unit): findings with certainty Proven/Likely/Unknown, each citing evidence ids, the change that preceded the failure, a remedy as data. Repeat the certainty, never raise it; cite the evidence ids; a precedent is a correlation, not a cause; a remedy is proposed, not applied. `recent_diagnoses(host, name)` shows whether it is new or recurring. A diagnosis also looks back on recent PAST incidents (a crash, OOM kill or exception before now, from the agent's incident ring) as `svc.recent_incident` — Likely, cited like any finding. Follow-ups on a stored diagnosis (its `id`): `export_diagnosis(id, format)` (checkmk/gelf/ansible/dsc/powershell), `send_diagnosis_gelf(id)` (forward it to the configured Graylog), `propose_remedy(id, finding)` (file the fix for a person to approve — never run here).
- **A host behind on updates / an update that failed?** `diagnose_updates(host)` — the host's own explainable diagnosis of the updates target (Windows Update, or apt/dnf on Linux): findings (upd.install_failed with its HRESULT, upd.reboot_pending, upd.wsus_unreachable, upd.held, upd.dpkg_interrupted, upd.behind, upd.up_to_date) with certainty and cited evidence, same honesty rules as diagnose_service.
- **Windows updates across the fleet?** `create_patch_ring(name, scope_type, …)` — install updates in ordered waves (canary → rings) with a health gate; it only plans the rollout, nothing installs until it is started.
- `fleet_health` / `list_problems` / `host_services(host)` — monitoring state; `get_host_logs`, `get_host_processes`.
- `get_server_document(host)` / `explain_server(host, question)` — the whole host as a document / NL Q&A grounded in live state.

**Configure ONE host** (a file on a single machine)
- `set_host_config(host, path, values, dry_run=True)` — converge a config file (codec-merged). Preview with dry_run, then apply.
- `get_host_desired_state(host)` — what is currently desired for the host.

**Configure MANY hosts = POLICY** (GPO model: author once, link to a scope)
- Scopes form a tree: `get_ou_tree` (OUs), `list_host_groups`, plus subnet **Sites**. Precedence: global < group < OU(deep) < Site < host (closest-to-host wins).
- A **named policy** groups several config-file entries; link it to an OU/Site to apply to every host under it. Thresholds: `set_threshold(...)`. Orchestration/role policies: `list_orchestration_plans`, `preview_orchestration_plan_link`, then `propose_orchestration_plan_link(...)` — the ONE gated write (starts pending human approval).
- **When to use which:** one host, one file → `set_host_config`. Same setting for a whole group/OU/subnet → a policy linked to that scope. A monitoring limit → `set_threshold`. A role/package rollout → an orchestration plan link.
- **Rule conditions (Checkmk-style):** any policy / threshold / check assignment can carry `conditions` that further narrow WHERE it applies, on top of its scope — matched against host tags, OS, **Ansible facts** (`host_facts`, dotted e.g. `os.family`), **desired-state variables** (`host_vars`), host/service name and OU folder. Empty = applies wherever the scope reaches. Set host-level levers directly with host tags / host variables (also via right-click on a host in Host placement).

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

**Generic resource lifecycle** (kinds: config | docker | helm | k8s | package | role | service | tunable) — `resource_observe` → `resource_plan` → `resource_apply(dry_run=True)` → `resource_rollback` / `resource_generations`.

**Deploy a VM** — `vm_hosts(placement=True)` lists hypervisors (nodes, storages, bridges) and golden images; `suggest_free_ips(prefix)` / `check_ip(addresses)` say whether an address is free by Bossman's records, NetBox and a live ping/ARP (never trust one source alone); `deploy_vm(..., image=<golden image> | install="fedora[-<release>]", dry_run=True)` runs every pre-flight check (netboot on, image ready or installer on the mirror, node/storage/bridge, hostname, address free), `dry_run=False` creates the VM and arms the PXE restore or the network install — the PXE DHCP then answers ONLY that VM's MAC; follow with `deployment_status(hostname)` (done = the new agent reported), `vm_status`/`vm_power` to look at or reset the VM, `set_netboot(enabled)` if netboot is off, then `update_agent(host)` if its agent is older.

**Kernel tuning** (docs/kernel-tuning.md) — you choose and parameterise, you never write scheduler code. A tunable is the resource kind `tunable`, named `sched_ext`, `cpu_governor`, `kernel_cmdline`, `systemd_resource:<unit>` or `blockdev_tuning:<device>`; `desired = {"params": {...}}` takes the agent module `yoloman.<tunable>`'s parameters (see `list_agent_tools`). First read what the kernel supports: `call_agent_tool(host, "setup")` → `yoloman_kernel_caps` (sched_ext state + reason, BTF, CONFIG_* flags, boot loader, init system). A plan says `persistence` (live | persistent | pending_reboot) and carries the undo; `action: refused` comes with `refusal.kind` = unsupported | tool_unavailable | conflict and the reason — report that reason instead of retrying. `resource_rollback(generation=0)` restores the state before yoloman managed the tunable. `kernel_cmdline` needs a reboot (`reboot` module) before it is live. When `sched_ext` is refused with `tool_unavailable: scx_<name>` (no distribution ships a working scx today), build it: `call_agent_tool(host, "yoloman.scx_install", {"proxy": "<http proxy if needed>"})` — state built | building (call again; it never starts a second build) | a failure with the build log; missing build tools come back as tool_unavailable with the package names to install with the package module. To learn whether a tunable HELPS, measure: `experiment_start(host, tunable, params, profile, runs=5..10)` alternates A/B runs, undoes every B and gives a verdict (better | worse | no_difference | inconclusive | aborted) with medians, p-value and the 2 % minimum effect — follow it with `experiment_status(id, wait_s=600)` and report the verdict as it is (inconclusive means: run more). `snapshot=true` rehearses on a Bossman-deployed Proxmox VM and rolls it back (needed for kernel_cmdline).

## Safety
Show diffs from dry-run/preview before applying. Use `blast_radius(host, resources)` for what-if. For fleet-wide changes prefer a policy link (`propose_orchestration_plan_link`, human-approved) over touching hosts one by one.
"""
