# The HTTP API, endpoint by endpoint

> **GENERATED** by `scripts/generate-api-reference.py` from a *running* server's `/openapi.json`, on
> 2026-08-28. Do not edit by hand — the next run overwrites it. It is generated from the running server
> rather than from the source because a route that the router never included does not exist for a
> caller, and measuring instead of reading the source caught exactly that twice here.

## How to read this, and how to use it

This is the complete callable surface of Bossman: **481 operations** across **69 groups**. It is written in prose on purpose. If you
are a language model working in this repository, this page plus [the developer guide](developing.md)
should be enough to call anything here correctly without reading the server's source first.

Three things hold everywhere and are not repeated per endpoint:

1. **Everything except `/healthz` and `/api/v1/auth/login` needs a bearer token.** `POST
   /api/v1/auth/login` with `{"username", "password"}` returns `access_token`; send it as
   `Authorization: Bearer <token>`.
2. **A host is addressed by its agent id**, not by its name — names are not unique across the
   lifetime of a fleet, and an endpoint that took a name would silently act on the wrong host after a
   rebuild. `GET /api/v1/agents` maps names to ids.
3. **A refusal says why.** A 4xx from this server carries a `detail` that names the reason; when an
   *agent* refuses something, the call still succeeds and the refusal is in the result body (outcome
   `refused`). Those two are different events and must not be collapsed: the first means the request
   was wrong, the second means the host said no.

Of the 481 operations, **290 carry a description** written in the handler
itself; **191 carry only a summary** and are marked as such below rather than being
quietly padded with invented prose. That number is the honest measure of how documented this API is.

### Related pages

- **[Developer guide](developing.md)** — the invariants, the contracts, and how to add a module, a
  check or an endpoint without breaking them. Read that first; this page is the lookup table.
- **[Windows modules](modules-windows.md)** and **[Linux modules](modules-linux.md)** — what the
  *agents* expose. Bossman's endpoints are how you reach them.
- **[Writing a check](checks-authoring.md)** — the Starlark contract, with a worked example.

## The groups

| Group | Endpoints | What it is |
|---|---|---|
| [management](#management) | 32 | Day-to-day operations on one host — services, packages, users, files, processes. **Changes things.** |
| [images](#images) | 30 | PXE: boot images, provisioning profiles and the hosts being installed right now. **Changes things.** |
| [ou](#ou) | 25 | Organisational units — the tree that policies, checks and configuration are inherited through. |
| [agents](#agents) | 23 | The fleet: enrolled hosts, their facts, their modules, and the calls that reach into one host. |
| [monitoring](#monitoring) | 22 | Check results as service states, with their history and their thresholds. |
| [resources](#resources) | 22 | Declared state: what a host is supposed to look like, and the plan/apply that gets it there. **Changes things.** |
| [orchestration](#orchestration) | 17 | Runbooks in flight: starting one, watching its steps, and the results per host. **Changes things.** |
| [chat](#chat) | 16 | The natural-language interface over the fleet, and the tools it is allowed to call. |
| [plans](#plans) | 15 | A plan is a proposed change with its diff, kept so it can be reviewed before it is applied. |
| [remediation](#remediation) | 15 | Closed-loop repair: a proposal, its guardrails, its autonomy setting, and its rollback. **Changes things.** |
| [blueprints](#blueprints) | 14 | A reusable bundle of declared state that can be applied to a new host. **Changes things.** |
| [checks](#checks) | 14 | The check catalogue: what can be measured, and which hosts a check is assigned to. |
| [runbooks](#runbooks) | 14 | The runbook library — the step lists themselves, before anyone runs them. |
| [docker](#docker) | 13 | Containers and compose projects discovered on a host, and their desired state. **Changes things.** |
| [templates](#templates) | 11 | Configuration templates — whole-file renders for configuration a codec cannot parse. |
| [users](#users) | 11 | Accounts in this server, and their roles. **Changes things.** |
| [dashboard](#dashboard) | 10 | The overview numbers, and the dashlets a user has arranged. |
| [search](#search) | 10 | Fleet-wide search — the saved searches and the query language behind the Fleet Overview. |
| [helm](#helm) | 9 | Kubernetes releases, as declared state. **Changes things.** |
| [systems](#systems) | 8 | Test systems: a clone of a production system, for rehearsing a change. **Changes things.** |
| [compliance](#compliance) | 6 | Software compliance: which hosts hold a version they should not. |
| [graphs](#graphs) | 6 | Metric series for plotting: what exists, and the points in a time range. |
| [host-groups](#host-groups) | 6 | Named sets of hosts, used wherever a policy or a rollout needs a target. |
| [notifications](#notifications) | 6 | Channels and escalation: who is told, how, and after how long. |
| [rollouts](#rollouts) | 6 | Staged change across many hosts, with the gate between stages. **Changes things.** |
| [sites](#sites) | 6 | Subnet-scoped policy: a site is a set of CIDRs, and a host belongs to one by its primary address. |
| [business-services](#business-services) | 5 | Aggregation: many technical states rolled into one service that a non-operator understands. |
| [document](#document) | 5 | The server-as-document view: one host as one JSON document, and its history. |
| [scheduler](#scheduler) | 5 | Recurring work: what runs when, and whether the last run succeeded. |
| [security](#security) | 5 | CVE exposure per host, and the actions taken about it. |
| [system-settings](#system-settings) | 5 | This server's own settings. |
| [time-periods](#time-periods) | 5 | Named windows — business hours, maintenance — that other rules refer to. |
| [change-proposals](#change-proposals) | 4 | Changes waiting for a human decision, with the reasoning that produced them. |
| [clusters](#clusters) | 4 | Hosts that belong together as one failure domain. |
| [value-maps](#value-maps) | 4 | Turning a raw number into the word a human reads. |
| [vm](#vm) | 4 | Virtual machine lifecycle on a hypervisor. **Changes things.** |
| [admin](#admin) | 3 | Server-side maintenance that is not about any one host. **Changes things.** |
| [agent-release](#agent-release) | 3 | Agent packages this server offers for installation and upgrade. |
| [audit](#audit) | 3 | Who did what, in this server. |
| [auth](#auth) | 3 | Logging in. Everything else needs the bearer token this returns. |
| [capabilities](#capabilities) | 3 | What a host can provide and what it requires — the matcher behind the lego model. |
| [config-templates](#config-templates) | 3 | The template catalogue itself: schemas, samples and the Jinja sources. |
| [deployments](#deployments) | 3 | A rollout in progress, per host. |
| [devices](#devices) | 3 | Things that are not hosts: switches, PDUs, anything polled off-host. |
| [enroll](#enroll) | 3 | How a host joins the fleet — the token it presents and the certificate it gets back. |
| [events](#events) | 3 | The event console: raw events before they are anything else. |
| [knowledge](#knowledge) | 3 | The retrieval memory the chat and the remediation reasoning read from. |
| [processes](#processes) | 3 | What is running on a host, and its resource use. |
| [apps](#apps) | 2 | Application definitions layered over hosts. |
| [chunks](#chunks) | 2 | The indexed pieces of that memory. |
| [config-fields](#config-fields) | 2 | One question, one answer: which fields does this configuration file have, and how is it written? |
| [config-sync](#config-sync) | 2 | Bringing a host's configuration back in line with what is declared for it. **Changes things.** |
| [forecast](#forecast) | 2 | Where a series is heading, for capacity questions. |
| [help](#help) | 2 | The in-product help texts. |
| [mmc](#mmc) | 2 | The management console: the snap-in tree, and one snap-in's rows and actions for one host. |
| [modules](#modules) | 2 | The Ansible-compatible module catalogue: specifications, and which are translated. |
| [runs](#runs) | 2 | One execution of something, whatever started it. |
| [severity-labels](#severity-labels) | 2 | The names this installation gives to severities. |
| [vault](#vault) | 2 | Secrets by reference: a runbook names a secret, never carries it. **Changes things.** |
| [activity](#activity) | 1 | What happened recently, as an operator's timeline. |
| [config-codecs](#config-codecs) | 1 | Which configuration files this system can parse, and with which grammar. |
| [config-directives](#config-directives) | 1 | Per-key knowledge for parsable configuration files: types, defaults and allowed values. |
| [health](#health) | 1 | Is this server alive. No token needed. |
| [package-catalog](#package-catalog) | 1 | Every package this system knows configuration for. |
| [package-qualify](#package-qualify) | 1 | The batch that classifies a package's configuration files. |
| [package-wizard](#package-wizard) | 1 | Guided setup for one package's configuration. |
| [relationships](#relationships) | 1 | Dependencies between objects, used to explain an outage by its cause. |
| [topology](#topology) | 1 | How hosts are connected, as measured rather than as drawn. |
| [translate](#translate) | 1 | Turning a catalogue specification into something an agent can execute. |

---

## management

Day-to-day operations on one host — services, packages, users, files, processes.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/agents/{agent_id}/accounts`

Block J4c — the host's users and groups, via the read-only `getent` module (passwd + group databases), parsed into a friendly shape. Each user carries `system` (uid < 1000) so the UI can separate human accounts from service accounts (shadow is not read — it needs root and isn't shown).

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/accounts/group`

Block J4c — create/remove a group via the write-gated `group` module.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `dry_run` (true or false, optional, default `false`)
- `gid` (string, optional)
- `state` (string, optional, default `"present"`)
- `system` (true or false, optional)

#### `POST /api/v1/agents/{agent_id}/accounts/user`

Block J4c — create/modify/remove a user via the write-gated `user` module. dry_run is honored by the module (check_mode).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `comment` (string, optional)
- `create_home` (true or false, optional)
- `dry_run` (true or false, optional, default `false`)
- `group` (string, optional)
- `groups` (string, optional)
- `home` (string, optional)
- `remove` (true or false, optional)
- `shell` (string, optional)
- `state` (string, optional, default `"present"`)
- `system` (true or false, optional)
- `uid` (string, optional)

#### `GET /api/v1/agents/{agent_id}/config-desired`

The GPO-resolved desired config for this host WITHOUT contacting the agent (unlike config-drift, which re-plans against the live host). Powers the "Configuration" section of the desired-state report — the merged config files and their per-key winning value + origin (host/OU/group/global).

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/config-desired/unset`

GPO "Not configured" (Block G): stop managing ONE key at one scope — remove it from the stored desired values. The live file is untouched (the key simply stops being enforced/drift-checked). Removing the last key deletes the whole desired row/policy.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `key` (string, required)
- `path` (string, required)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)

#### `GET /api/v1/agents/{agent_id}/config-drift`

Drift for this host (Block K3): re-plan every desired config resource Bossman has recorded against the host's live state. A resource whose plan action isn't 'noop' has drifted (someone/something changed the file out of band). Returns the managed paths + the drifted ones with their per-key changes — the same plan shape the value editor's preview uses.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/config/reapply`

Re-sync the host to its effective desired config (Block K3/K4): re-apply every resolved resource (host-direct + inherited OU policies) through the document loop, converging any drift and recording a generation.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/cves`

CVEs that this host's pending upgrades would fix — correlated live and persisted (so the fleet Security page has fresh data for viewed hosts).

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/logs`

Block J4b — the host's system log: journald on Linux, the Windows event log on Windows.

ONE SCREEN, TWO LOG SYSTEMS, and the branch is here rather than in the agent. The alternative was a Windows module answering to the name `journal`, which would have been a lie in the one place a reader checks what they are looking at — journald and the event log are not the same thing wearing two names (one has units and syslog priorities, the other channels and five levels). So the Windows agent keeps `windows_eventlog` under its own name, and this endpoint maps the screen's filters onto whichever log the host actually has, then returns ONE entry shape so the panel needs no branch:

time / message both have them unit the event PROVIDER on Windows — the thing that produced the line priority the LEVEL NAME (critical, error, warning, information, verbose) channel, event_id Windows-only, carried for the ones that have them

`log_source` says which log answered, because "no entries" from a journal and from an event log are different facts and the screen should be able to say which.

In the path:

- `agent_id` (string, required)

Query parameters:

- `lines` (whole number, optional, default `200`) — Most recent N journal entries
- `unit` (string, optional) — Restrict to one systemd unit
- `priority` (string, optional) — Syslog priority (0-7 or a name like 'err')
- `since` (string, optional) — journalctl time spec, e.g. '-1h' or 'yesterday'
- `grep` (string, optional) — MESSAGE regex
- `boot` (true or false, optional, default `false`) — Current boot only

#### `GET /api/v1/agents/{agent_id}/logs/file`

Tail one log file (last N lines, optional grep) via `logfiles`. `grep` is a plain substring, an extended regex when regex=true (grep -E), and inverted when invert=true (grep -v). The module rejects any path outside /var/log + the configured custom roots.

In the path:

- `agent_id` (string, required)

Query parameters:

- `path` (string, required) — Log file path (must resolve within an allowed root)
- `lines` (whole number, optional, default `500`)
- `grep` (string, optional)
- `regex` (true or false, optional, default `false`) — Treat grep as an extended regex (grep -E)
- `invert` (true or false, optional, default `false`) — Keep lines that do NOT match grep (grep -v)
- `extra_paths` (list of string, optional)

#### `GET /api/v1/agents/{agent_id}/logs/files`

Enumerate the host's plain-text log files under /var/log (+ any custom paths) via the read-only, path-jailed `logfiles` module.

In the path:

- `agent_id` (string, required)

Query parameters:

- `extra_paths` (list of string, optional) — Extra custom log files/dirs to include

#### `GET /api/v1/agents/{agent_id}/network`

Block J4e — the host's current network config (interfaces/addresses/ routes/DNS) via the baked yoloman.network_interface module in gathered mode (parses `ip` output; read-only).

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/network`

Block J4e — configure or remove an interface via the write-gated baked yoloman.network_interface module. The module auto-detects the host's network provider (NetworkManager / netplan / systemd-networkd / ifupdown), or the caller may force one via `provider`. dry_run is honored by the module (check_mode); a host with no supported provider fails cleanly (502).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `address` (string, optional)
- `dns` (list of string, optional)
- `dry_run` (true or false, optional, default `false`)
- `gateway` (string, optional)
- `mac` (string, optional)
- `method` (string, optional)
- `mtu` (whole number, optional)
- `provider` (string, optional)
- `state` (string, optional, default `"present"`)

#### `GET /api/v1/agents/{agent_id}/operations`

One host's result log, newest first — the same records the host itself keeps, plus the ones its ring has already discarded. Coverage is stated rather than implied: `collected_range` says which of the agent's own sequence numbers we hold, so "no records" and "we never collected any" are distinguishable.

In the path:

- `agent_id` (string, required)

Query parameters:

- `module` (string, optional)
- `outcome` (string, optional)
- `limit` (whole number, optional, default `200`)

#### `GET /api/v1/agents/{agent_id}/piggyback`

Block F5 — the guests this host reports on behalf of (CheckMK piggyback): Docker containers, Proxmox/vSphere/libvirt VMs. Proxies the agent's hosts/overview and keeps the entries that are guests (a parent set, or a container/vm mode) — the host itself is dropped. Each guest carries its latest metrics so the Virtualization tab can show CPU/mem/running.

In the path:

- `agent_id` (string, required)

#### `DELETE /api/v1/agents/{agent_id}/piggyback/sources`

F-9 — remove a remote piggyback source (by type + host) on this host.

In the path:

- `agent_id` (string, required)

Query parameters:

- `type` (string, required)
- `host` (string, required)

#### `GET /api/v1/agents/{agent_id}/piggyback/sources`

F-9 — the piggyback sources this host is configured to report guests from (Docker/Proxmox/vSphere/libvirt), each with a live reachability status + guest count. Makes the sources visible in their own right, not only via the guests they produce (which the /piggyback endpoint lists).

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/piggyback/sources`

F-9 — add/replace a remote piggyback source (Proxmox/vSphere) on this host at runtime: the agent persists it to its config.yaml and reloads its collectors, no restart. Write-gated on the agent.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `host` (string, required)
- `type` (string, required)
- `insecure` (true or false, optional, default `false`)
- `password` (string, optional, default `""`)
- `user` (string, optional, default `""`)

#### `GET /api/v1/agents/{agent_id}/policy-conflicts`

Where THIS system's declared registry values collide with WINDOWS' OWN POLICY TERRITORY.

The sentence this endpoint exists to produce: *"Something else holds AUOptions = 3, this policy declares 4, the policy area wins — your convergence will write ours and find it reverted, on every pass."* Without it that is a mystery an operator watches for weeks: the value keeps reverting and nothing says why.

Reads both sides out of what is already stored, so it contacts no host: ours from the GPO-resolved config resources (group < OU < site < host, with the per-key winner), Windows' from `facts.group_policy.policy_area_values` — the values sitting in the Group-Policy-owned registry subtrees, refreshed every six hours by the poller.

WHAT THE OTHER SIDE IS, exactly, because the report's honesty depends on it: measured on the test host, `gpresult /X` names WHICH GPOs applied and which extensions ran and carries no per-setting data at all. So the comparison is against the registry area both authorities write to — a DIFFERING value is evidence of a foreign authority (we would have written ours), an EQUAL value is evidence of nothing and is reported as `same_value`, never as "Group Policy agrees". `imposed_source` travels with the report so no consumer has to guess how strong the claim is.

FOUR OUTCOMES, and three of them are not conflicts: `overridden` (the finding), `same_value` (nothing contradicts us), `in_gp_scope` (nobody claims that name yet, and the next refresh can), `ours_alone` (counted only). A report that called all four a conflict would teach people to close it.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/service-units`

Block J4a — the host's systemd service units + their load/active/sub state, via the read-only `service_facts` module. The UI drives its per-unit start/stop/restart/enable/disable off this list (each action goes to POST /agents/{id}/service-control).

Path is /service-units, not /services: the latter is the monitoring read route (GET /agents/{id}/services -> list[ServiceOut] of graded check states) and the two must not collide on the router.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/state/apply`

Converge a desired config Document on the host (Block K1), proxying the agent's POST /api/v1/state/apply. dry_run previews (the plan) without writing; a real apply writes through the codec merge and records a generation (so every edit is versioned + roll-backable). A read-only agent rejects the write → surfaced as 502.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `dry_run` (true or false, optional, default `true`)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `resources` (list of object, optional, default `[]`)

#### `GET /api/v1/agents/{agent_id}/state/generations`

The agent's local desired-state generation history (plan/apply/rollback store), proxied from GET /api/v1/state/generations. Distinct from Bossman's own compiled-desired-state generations (CompiledHostState) — this is what the host itself has applied and can roll back to.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/state/observed`

The host as one JSON document (Block F1, the server-as-a-document read): discovered services + each config file read back structured via its codec.

Served from Bossman's Postgres cache (refreshed by the background poller) so the Configuration view opens instantly — NOT a live pass-through per open, which was slow. Pass ?refresh=true (the UI's Reload button) to force a live fetch from the agent and update the cache. If the cache is empty and no refresh was asked, we do one live fetch and populate it.

In the path:

- `agent_id` (string, required)

Query parameters:

- `refresh` (true or false, optional, default `false`)

#### `POST /api/v1/agents/{agent_id}/state/plan`

Diff a desired config Document against the host (Block K1), proxying the agent's POST /api/v1/state/plan — the per-key preview behind the value editor. Read-only; writes nothing.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `resources` (list of object, optional, default `[]`)

#### `POST /api/v1/agents/{agent_id}/state/rollback`

Roll the host's config back to a past generation (Block F2), proxying the agent's POST /api/v1/state/rollback. dry_run (default) returns the plan — the observed→target diff — without writing; a real rollback needs the agent's write gate open, which a read-only agent rejects (surfaced as 502).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `generation` (whole number, required)
- `dry_run` (true or false, optional, default `true`)

#### `GET /api/v1/agents/{agent_id}/storage`

Block J4d — a read-only storage overview: block devices + LVM + VDO via the native storage_facts module, plus ZFS pools via the baked zpool_facts module. ZFS is fetched separately and degrades on its own (a host without zfs makes zpool_facts fail — reported as {available: false}, not a 502). Write actions (create/remove VG/LV/filesystem/VDO/ZFS) go through the generic tool router POST /agents/{id}/tools/{fqcn}.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/tools`

Every tool one managed agent currently exposes ([{name, kind, writes}]), proxied from the agent's own GET /api/v1/tools. Write tools appear only when that agent's write gate is open.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/tools/{tool_name}`

Route a single tool call to one managed agent (proxies the agent's POST /api/v1/tools/{name}). The agent's write gate + ACL + audit are the enforcement point; a read-only agent rejecting a write tool surfaces as a 502 with the agent's message.

In the path:

- `agent_id` (string, required)
- `tool_name` (string, required)

The JSON body carries:

- `params` (object, optional, default `{}`)
- `timeout_seconds` (number, optional)

#### `GET /api/v1/agents/{agent_id}/updates`

Cockpit "Software updates" — pending OS package updates via the baked yoloman.package_updates module (apt / dnf / yum, auto-detected). Refreshes the package index (apt update / dnf metadata), so it mutates the cache but not the system; read-only w.r.t. installed packages.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/updates`

Cockpit "Apply (security) updates" — installs pending updates via the write-gated yoloman.package_updates module. dry_run is honored (check_mode); security_only installs only security updates (apt: unattended-upgrade; dnf: --security).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `dry_run` (true or false, optional, default `false`)
- `security_only` (true or false, optional, default `false`)

#### `GET /api/v1/agents/{agent_id}/virt`

Local virtualization overview: which hypervisor stack(s) this host runs (Proxmox qm/pct, libvirt virsh) and their guests, via the read-only virt_facts module. Guest control goes through the generic tool router POST /agents/{id}/tools/{qm|virsh}.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/operations`

WHAT THE FLEET DID — every collected operation record, newest first.

The fleet-wide half of the result log (docs/windows-management.md §8 milestone 9). The agent keeps its own ring and answers for itself; this answers questions no single host can — "which hosts refused this", "what changed in the last hour", "did that install ever complete anywhere".

Filters are ANDed and every one is optional. `outcome` is validated against the fixed vocabulary rather than passed through, because a typo that silently matches nothing reads exactly like "it never happened".

Query parameters:

- `host` (string, optional)
- `agent_id` (string, optional)
- `module` (string, optional)
- `outcome` (string, optional)
- `since` (string, optional)
- `changed_only` (true or false, optional, default `false`)
- `limit` (whole number, optional, default `200`)

---

## images

PXE: boot images, provisioning profiles and the hosts being installed right now.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/images`

List Images. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/images`

Register an image and mark it `capturing`. The capture itself runs on the source host.

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)
- `source_agent_id` (string, optional)

#### `POST /api/v1/images/import`

Create the DiskImage (capturing) and launch import-image.sh detached in the pxe container; it captures every volume and finishes the image itself (via the per-image token), so the WebUI just watches the image go capturing → ready (or failed).

The JSON body carries:

- `name` (string, required)
- `source_file` (string, required)
- `description` (string, optional, default `""`)

#### `GET /api/v1/images/import/sources`

Disk-image files staged in the lab (what the WebUI Import picker offers).

#### `DELETE /api/v1/images/{image_id}`

Deleting an image deletes its restore-job history with it (ON DELETE CASCADE), so an active job blocks the delete — otherwise a machine mid-install would lose the plan it is executing.

In the path:

- `image_id` (string, required)

#### `GET /api/v1/images/{image_id}`

Get Image. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `image_id` (string, required)

#### `PATCH /api/v1/images/{image_id}`

Mark a template active (only one at a time) and/or set its grow policy (root/var/home %).

In the path:

- `image_id` (string, required)

The JSON body carries:

- `grow_mode` (string, optional)
- `grow_policy` (object, optional)
- `is_active` (true or false, optional)

#### `POST /api/v1/images/{image_id}/capture-plan`

Plan a capture the same way the restore plans an install: the container reports lsblk+sfdisk and gets back the manifest (layout_to_dict) plus the per-volume list (stem/fs/partclone tool + how to address the volume). Token-auth'd, since it is the capturing import driving it, not an operator.

In the path:

- `image_id` (string, required)

The JSON body carries:

- `lsblk` (object, required)
- `sfdisk` (object, optional, default `{}`)

#### `PUT /api/v1/images/{image_id}/files/{stem}`

Stream one volume's compressed image in, hashing it as it lands.

Streamed, never buffered: these files are gigabytes, and reading one into memory to hash it would take the process down on the first real capture.

The checksum is computed HERE, on what actually arrived, rather than being reported by the sender. That is the whole point — a truncated upload is exactly what a sender cannot notice, and a truncated image written to a disk is an unbootable machine that looks like a successful restore.

In the path:

- `image_id` (string, required)
- `stem` (string, required)

#### `POST /api/v1/images/{image_id}/finish`

Record the manifest, fold in the measured usage, and mark the image deployable.

The image only becomes `ready` if it is actually restorable: the manifest must parse, every volume must have a stored file, and the usage must be known — otherwise `plan_restore` cannot even decide whether a target is big enough, and the failure would surface at 3am on the machine being installed instead of here.

In the path:

- `image_id` (string, required)

The JSON body carries:

- `manifest` (object, required)
- `used_bytes` (object, optional, default `{}`)

#### `POST /api/v1/images/{image_id}/import-failed`

The import script reports a failure so the WebUI shows the reason instead of a stuck 'capturing'.

In the path:

- `image_id` (string, required)

The JSON body carries:

- `error` (string, optional, default `"import failed"`)

#### `POST /api/v1/images/{image_id}/import-progress`

The import script reports progress so the WebUI can show a live bar while status is 'capturing'.

In the path:

- `image_id` (string, required)

The JSON body carries:

- `message` (string, optional, default `""`)
- `percent` (whole number, optional)

#### `POST /api/v1/netboot/checkin`

A netbooted machine reports its MAC and disks and receives its plan.

This is where the restore is planned, because it is the first moment the target's real disk size is known — and that size is what decides how far the last volume grows.

The JSON body carries:

- `mac` (string, required)
- `blockdevices` (list of object, optional, default `[]`)

#### `GET /api/v1/netboot/config`

The effective netboot state for the pxe container to consume, so the WebUI is the ONLY source of the secret — no env/override to keep in sync. Returns the secret only to an ENROLLED agent (the pxe-lab host proving itself with its own token) and only while netboot is enabled; the container stamps it onto the PXE kernel cmdline and gates DHCP on `dhcp`.

#### `GET /api/v1/netboot/pending`

Whether the PXE DHCP should be answering right now: true iff a restore job is armed (pending) or mid-flight (running). The pxe container polls this and toggles dnsmasq's DHCP, so it only serves boot requests while there is actually an order to fulfil — no standing DHCP/PXE on the segment otherwise.

#### `POST /api/v1/netboot/progress/{job_id}`

The helper reports how far it got. Append-only log, monotonic index.

The index never moves backwards: a retried step would otherwise make progress look like it regressed, and an operator watching a long install would read that as a loop.

In the path:

- `job_id` (string, required)

The JSON body carries:

- `step_index` (whole number, required)
- `done` (true or false, optional, default `false`)
- `error` (string, optional)
- `failed` (true or false, optional, default `false`)
- `log` (string, optional, default `""`)

#### `POST /api/v1/provisioning/hosts`

Create a bare-metal target as an Agent in state 'planned'. It then shows up in the fleet like any host, so roles are assigned through the normal Management tab; the netboot check-in enrol-links it by hostname. The MAC + final network are kept in agent_metadata until the install writes them.

The JSON body carries:

- `hostname` (string, required)
- `mac` (string, optional, default `""`)
- `network` (object, optional, default `{}`)
- `roles` (list of string, optional, default `[]`)
- `write` (true or false, optional, default `true`)

#### `GET /api/v1/provisioning/templates`

List Deployment Templates. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/provisioning/templates`

Create or overwrite a template by name (idempotent save): re-saving under the same name updates it, so the wizard's "Save as template" is a plain upsert rather than a create-then-409.

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)
- `grow_mode` (string, optional, default `"percent"`)
- `grow_policy` (object, optional, default `{}`)
- `image_id` (string, optional)
- `network` (object, optional, default `{}`)
- `roles` (list of string, optional, default `[]`)

#### `DELETE /api/v1/provisioning/templates/{template_id}`

Delete Deployment Template. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `template_id` (string, required)

#### `GET /api/v1/provisioning/vm-hosts`

List Vm Hosts. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/provisioning/vm-hosts`

Register a hypervisor: detect whether it is Proxmox or vCenter from the host + credentials (the operator does not choose), then store it with the password vault-encrypted. Detection failure is a 422 with the probe's reason, so a wrong host/credential is obvious.

The JSON body carries:

- `host` (string, required)
- `name` (string, required)
- `password` (string, required)
- `username` (string, required)
- `verify_tls` (true or false, optional, default `false`)

#### `DELETE /api/v1/provisioning/vm-hosts/{host_id}`

Delete Vm Host. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `host_id` (string, required)

#### `POST /api/v1/provisioning/vm-hosts/{host_id}/auto-provision`

Create the VM, then bind its MAC to a fresh planned host + restore job in one call — the single endpoint a blueprint→PXE job uses. Returns the created {vmid, mac}, the planned host id, and the armed restore job.

Sequence (each step reuses the same logic the standalone endpoints do, so there is no behavioural drift): 1. create-vm on the hypervisor -> {vmid, mac} 2. planned host with provision_mac = that mac (upsert by hostname) 3. restore job with target_mac = that mac (+ VLAN handoff pointing at the VM)

In the path:

- `host_id` (string, required)

The JSON body carries:

- `bridge` (string, required)
- `hostname` (string, required)
- `image_id` (string, required)
- `name` (string, required)
- `node` (string, required)
- `storage` (string, required)
- `cores` (whole number, optional, default `2`)
- `disk_gib` (whole number, optional, default `32`)
- `memory_mb` (whole number, optional, default `2048`)
- `network` (object, optional, default `{}`)
- `production_bridge` (string, optional)
- `production_vlan` (whole number, optional)
- `roles` (list of string, optional, default `[]`)
- `target_disk` (string, optional)
- `uefi` (true or false, optional, default `false`)
- `vlan` (whole number, optional)
- `write` (true or false, optional, default `true`)

#### `POST /api/v1/provisioning/vm-hosts/{host_id}/create-vm`

Create + start a PXE-install VM on this hypervisor and return {vmid, mac}. The caller then creates a planned host with that MAC and arms the restore job — the VM PXE-boots into the restore. VM creation is optional provisioning: the bare-metal path (an operator-typed MAC) is unchanged.

In the path:

- `host_id` (string, required)

The JSON body carries:

- `bridge` (string, required)
- `name` (string, required)
- `node` (string, required)
- `storage` (string, required)
- `cores` (whole number, optional, default `2`)
- `disk_gib` (whole number, optional, default `32`)
- `memory_mb` (whole number, optional, default `2048`)
- `uefi` (true or false, optional, default `false`)
- `vlan` (whole number, optional)

#### `GET /api/v1/provisioning/vm-hosts/{host_id}/placement`

What a VM needs placed on this hypervisor: nodes/hosts, the storages/datastores that can hold a disk, and the networks/bridges a NIC attaches to — so the wizard can offer them.

In the path:

- `host_id` (string, required)

#### `GET /api/v1/restore-jobs`

List Restore Jobs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/restore-jobs`

Arm a machine for installation. No steps yet — they are computed when it checks in and says which disks it has, because that is the first moment anyone knows.

The JSON body carries:

- `image_id` (string, required)
- `target_hostname` (string, required)
- `production_bridge` (string, optional)
- `production_vlan` (whole number, optional)
- `target_disk` (string, optional)
- `target_mac` (string, optional, default `""`)
- `vm_host_id` (string, optional)
- `vm_id` (string, optional)
- `vm_node` (string, optional)

#### `DELETE /api/v1/restore-jobs/{job_id}`

Remove a finished job from the list. A still-active job must be cancelled first — deleting one mid-install would just lose the record of what a machine is currently doing.

In the path:

- `job_id` (string, required)

#### `POST /api/v1/restore-jobs/{job_id}/cancel`

Cancelling a *running* job does not stop the machine — it has the plan already and no channel back. It marks our intent and frees the MAC; the target has to be reset by hand.

In the path:

- `job_id` (string, required)

---

## ou

Organisational units — the tree that policies, checks and configuration are inherited through.

#### `PUT /api/v1/agents/{agent_id}/ou`

A host lives at exactly one OU (the AD model) — setting it here replaces any prior placement rather than adding to it. NULL un-places the host (root/unassigned).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `ou_id` (string, required)

#### `GET /api/v1/config-policies`

Config policies WITH their values documents, for the Policy-console gpedit editor (the OU objects list only carries a label). Filter by OU, group or Site scope, or by `set_id` (a named policy's entries); `unlinked=true` returns the scope-less policies not yet linked; no filter returns all.

Query parameters:

- `scope_ou_id` (string, optional)
- `host_group_id` (string, optional)
- `site_id` (string, optional)
- `set_id` (string, optional)
- `unlinked` (true or false, optional, default `false`)

#### `POST /api/v1/config-policies`

Create/update a config policy at OU/group scope and converge members (Block K4, authored from the Policy console). No agent context needed — you can define a policy for an OU that has no reachable host yet; it applies when hosts appear/re-sync.

The JSON body carries:

- `path` (string, required)
- `conditions` (object, optional, default `{}`)
- `dry_run` (true or false, optional, default `false`)
- `format` (string, optional, default `"keyvalue"`)
- `host_group_id` (string, optional)
- `scope_ou_id` (string, optional)
- `separator` (string, optional)
- `set_id` (string, optional)
- `site_id` (string, optional)
- `template` (string, optional)
- `type` (string, optional, default `"config"`)
- `values` (object, optional, default `{}`)

#### `POST /api/v1/config-policies/unset`

GPO "Not configured" at OU/group scope, agent-free (the Policy-console editor's counterpart of /agents/{id}/config-desired/unset): stop managing ONE key in a scope policy. Member hosts keep their live value; removing the last key deletes the policy row.

The JSON body carries:

- `key` (string, required)
- `path` (string, required)
- `host_group_id` (string, optional)
- `scope_ou_id` (string, optional)
- `site_id` (string, optional)

#### `DELETE /api/v1/config-policies/{policy_id}`

Remove an OU config policy (Block K4). Member hosts keep the last-applied file until re-synced — deleting the policy just stops distributing it; it does not revert hosts (mirrors unlinking a GPO).

In the path:

- `policy_id` (string, required)

#### `GET /api/v1/config-policies/{policy_id}`

One config policy by id WITH its values — so a selected policy (in the tree or palette) can show exactly what it sets, without knowing its scope up front.

In the path:

- `policy_id` (string, required)

#### `PATCH /api/v1/config-policies/{policy_id}`

Move a config policy to another OU/group scope (the OU-console 'drag a placed policy onto another OU' gesture). Exactly one of scope_ou_id / host_group_id. Doesn't re-converge here — member hosts pick it up on their next sync (deleting/adding a scope link mirrors unlinking a GPO).

In the path:

- `policy_id` (string, required)

The JSON body carries:

- `host_group_id` (string, optional)
- `scope_ou_id` (string, optional)
- `site_id` (string, optional)

#### `GET /api/v1/match-vocabulary`

Known keys+values for the rule-conditions editor's live search: host tag groups → values, Ansible fact keys (dotted) → values, desired-state variable keys → values, host label keys → values, and the OU folder paths. Free-text is still allowed — this only powers the suggestion dropdowns so tags / facts / variables and their values auto-complete instead of being typed blind.

#### `GET /api/v1/ou`

List Ou Nodes. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/ou`

Create Ou Node. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `parent_id` (string, optional)

#### `DELETE /api/v1/ou/{ou_id}`

Delete Ou Node. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `ou_id` (string, required)

#### `PATCH /api/v1/ou/{ou_id}`

Toggle GPO "Block Inheritance" on an OU. Since this changes which inherited rules apply to every host in this OU's subtree, it recompiles them all (analogous to a plan-link change).

In the path:

- `ou_id` (string, required)

The JSON body carries:

- `block_inheritance` (true or false, required)

#### `GET /api/v1/ou/{ou_id}/ancestry`

Get Ou Ancestry. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `ou_id` (string, required)

#### `GET /api/v1/ou/{ou_id}/members`

Agents in this OU's SUBTREE (policy semantics — a policy on /Munich reaches hosts in /Munich/mue-0 too). The Policy-console gpedit editor uses the first reachable member as its settings catalog ("Host A = Host B").

In the path:

- `ou_id` (string, required)

#### `POST /api/v1/ou/{ou_id}/move`

Reparent an OU (the drag-and-drop move, Block L3e). Rewrites the materialized `path` + `ltree_path` of the node AND its whole subtree, then recompiles every host under it (OU-scoped rules + GPO precedence change with the new depth/ancestry). Rejects a move into the node's own subtree (a cycle) and a name collision under the new parent.

In the path:

- `ou_id` (string, required)

The JSON body carries:

- `parent_id` (string, optional)

#### `GET /api/v1/ou/{ou_id}/objects`

Every policy object attached DIRECTLY to this OU (not inherited) — check-rules/thresholds, notification rules, host groups, and orchestration plan links — the child nodes the GPO tree shows under an OU. Inheritance/effective resolution is a separate concern (the compiler / desired-state view).

In the path:

- `ou_id` (string, required)

#### `GET /api/v1/policy-lint`

Static analysis over the policy tree — unlinked/empty policies, thresholds with no warn/crit, and conditions whose tag/fact/variable/label key no host currently has ("why doesn't my policy apply?"). Read-only.

#### `GET /api/v1/policy-report`

Resultant Set of Policy for one scope — what actually applies to hosts here and WHERE each rule comes from. Unlike the objects endpoint (own-scope only), this INHERITS: an OU shows its own policies plus everything from its ancestor OUs and the global tier; a Site shows its own plus global; a group its own plus global. Origin is labelled so you can see 'here' vs inherited. Ordering follows OUR precedence (weakest first, closest-to-host last) so the bottom rows win.

This backs the right-hand 'policy report' on the OU/Policy page (replacing the inline editor there) and finally surfaces OU/group Variables, which were set but never shown.

Query parameters:

- `scope_type` (string, required)
- `scope_id` (string, required)

#### `GET /api/v1/policy-sets`

The named-policy library (Miller column 1): every policy with its entry count + where (if anywhere) it is linked.

#### `POST /api/v1/policy-sets`

Create an empty named policy (unlinked). Entries are added via POST /config-policies with this set's id.

The JSON body carries:

- `name` (string, required)
- `description` (string, optional)

#### `DELETE /api/v1/policy-sets/{set_id}`

Delete a policy and all its entries (cascade).

In the path:

- `set_id` (string, required)

#### `GET /api/v1/policy-sets/{set_id}`

One policy with its entries + the flat 'all values' list (Miller columns 2 and 3).

In the path:

- `set_id` (string, required)

#### `PATCH /api/v1/policy-sets/{set_id}`

Rename / describe / (un)link a policy. Linking sets the scope on the set AND propagates it to every entry, so the per-(scope,path) compiler applies the whole policy at that scope; unlink detaches all entries (they go inert).

In the path:

- `set_id` (string, required)

The JSON body carries:

- `conditions` (object, optional)
- `description` (string, optional)
- `host_group_id` (string, optional)
- `name` (string, optional)
- `scope_ou_id` (string, optional)
- `site_id` (string, optional)
- `unlink` (true or false, optional, default `false`)

#### `POST /api/v1/policy/propose-nl`

Natural language → a reviewable config-policy proposal + its blast radius. Never applies anything — the caller reviews and creates it (dry_run first).

The JSON body carries:

- `instruction` (string, required)
- `backend` (string, optional)

#### `POST /api/v1/whatif/scope`

Which hosts a policy at this scope + these conditions WOULD apply to, before creating it — {total_in_scope, matched_count, matched, excluded}.

The JSON body carries:

- `scope_type` (string, required)
- `agent_id` (string, optional)
- `conditions` (object, optional, default `{}`)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `site_id` (string, optional)

---

## agents

The fleet: enrolled hosts, their facts, their modules, and the calls that reach into one host.

#### `GET /api/v1/agents`

Every host in the fleet, with its facts, its state and its addresses.

This is the call that maps a host **name** to the **agent id** the rest of the API is addressed by. Names are not unique over a fleet's lifetime; an endpoint that took a name would act on the wrong host after a rebuild.

One deliberate omission: **infrastructure agents are not listed.** The silent poller that reaches SNMP and SSH devices ("selecta") is an agent in the database and not a monitored host, so it would appear as a host that never has any of the things a host has. It is filtered here rather than in the UI, so every client sees the same fleet.

#### `POST /api/v1/agents/mass-update/facets`

Bulk-assign the searchable host facets — criticality, site and tags — across many selected hosts in one call (the 'select rows in a search result → tag/criticality/site them' flow). Same per-host manage ACL as mass_update_agent_groups.

The JSON body carries:

- `agent_ids` (list of string, required)
- `add_tags` (object, optional, default `{}`)
- `criticality` (string, optional)
- `remove_tags` (list of string, optional, default `[]`)
- `site` (string, optional)

#### `POST /api/v1/agents/mass-update/groups`

Zabbix gap-analysis Block K2c ("Mass update"): bulk-edit host-group membership across many selected agents in one call, instead of one PATCH per host. Scoped to the one field Bossman's Agent model actually has a bulk-editable equivalent for today (groups) — templates/macros/ inventory/encryption mass-editing has no Bossman counterpart yet (see docs/zabbix-gap-analysis.md's Batch 2).

The JSON body carries:

- `agent_ids` (list of string, required)
- `groups` (list of string, required)
- `op` (string, required)

#### `DELETE /api/v1/agents/{agent_id}`

Remove a host (agent) and everything it owns. Satellites that used this agent as their proxy parent are orphaned (parent_agent_id → NULL), not deleted — deleting a proxy must not silently take its satellites with it. All in one transaction, so a mid-delete failure leaves the host intact.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}`

One host: its facts, its enrollment state, its addresses and its versions.

404 when there is no such id — including for an infrastructure agent's id, which `list_agents` does not return either.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/collect-config`

Change what this host collects and let its agent restart to apply — without SSH.

The reason this exists: `update-bundled` replaces only the binary, config.yaml is noreplace, so turning off an unread high-cardinality family (service_* was 38.8% of the metrics DB) otherwise meant editing /etc/agentic-mcp/config.yaml on every host by hand. The agent's collect-config endpoint is a deliberate write-gate carve-out (like self-update), scoped strictly to the collect block, so a read-only host is still reconfigurable by its owner over the existing mTLS channel.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `docker` (true or false, optional)
- `drbd_devices` (true or false, optional)
- `interval` (string, optional)
- `psi` (true or false, optional)
- `services` (true or false, optional)
- `write` (true or false, optional)

#### `GET /api/v1/agents/{agent_id}/disks`

The host's disk + partition layout (gparted-style Disks view, read-only): disks with their partitions (fs, mount, used/avail, flags), the partition-table type, and FREE segments. Live read over the agent (lsblk + parted).

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/disks/apply`

Run the op queue on the host (guarded: loop-only unless allow_nonloop).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `allow_nonloop` (true or false, optional, default `false`)
- `ops` (list of string, optional, default `[]`)

#### `POST /api/v1/agents/{agent_id}/disks/preview`

Compile the op queue to concrete commands + a safety verdict — nothing runs.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `allow_nonloop` (true or false, optional, default `false`)
- `ops` (list of string, optional, default `[]`)

#### `POST /api/v1/agents/{agent_id}/disks/scratch`

Create/destroy a throwaway loopback disk so partition ops can be tested for real without a spare disk.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `action` (string, optional, default `"create"`)
- `backing_file` (string, optional)
- `device` (string, optional)
- `size_mb` (whole number, optional, default `256`)

#### `POST /api/v1/agents/{agent_id}/disks/tools`

Install the packages that provide the disk tools a host is missing (the Disks view's "install missing tools" button). The read-only scan only REPORTS what is missing — installing on a mere page view would be a surprising side effect — while `disks/apply` still auto-installs whatever its plan needs.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `bins` (list of string, optional, default `[]`)

#### `PATCH /api/v1/agents/{agent_id}/groups`

Host-group membership (see docs/plan.md's monitoring Block E2/E3) — the unit a check_rules row can target with scope_type=group, which a host-scoped rule can then override. Replaces the whole list rather than adding/removing one at a time, matching how the Settings UI's host-groups editor naturally works (a multi-select, not a diff).

Writes through services/host_membership, which owns `host_group_members` and derives `agents.groups` from it. Assigning the array directly (as this did) left the membership table untouched, so the group editor and this endpoint reported different memberships for the same host — see that module's header for the measurement.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `groups` (list of string, required)

#### `GET /api/v1/agents/{agent_id}/metrics`

This host's metrics: the catalogue, or the points of one series.

**Two modes in one endpoint, and the parameter decides which.** Without `metric` you get the *catalogue* — which series this host has ever reported, so a caller can find out what is measurable before asking for numbers. With `metric` you get that series' points, optionally from `since` onwards.

The catalogue is what a host *has reported*, not what it *could* report: a series appears once the first sample arrives and stays afterwards. For the newest sample of every series in one call, use `.../metrics/latest` instead of fanning out one request per name.

In the path:

- `agent_id` (string, required)

Query parameters:

- `metric` (string, optional) — Metric name to fetch points for; omit for catalog discovery
- `since` (string, optional) — Only points at or after this time

#### `GET /api/v1/agents/{agent_id}/metrics/latest`

The whole latest-data snapshot in one call: the newest sample of every metric this agent has ever reported. Powers the host-detail Metrics tab's list view (a metric name + last value + last check per row) so it no longer has to fan out one series request per metric just to show a value. `DISTINCT ON (metric)` + `time DESC` = Postgres' idiomatic latest-per-group; ordered by metric name for a stable list.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/metrics/snapshot`

Latest sample per unique (metric, labels) SERIES — one row per filesystem for disk_used_pct, one per check_*_state — powering the host Overview cockpit's per-mount gauges + services grid.

Served straight off the normalized base tables (`metrics_raw` + `metric_series`) with DISTINCT ON (series_id), which rides the series_id segmentation + time-DESC ordering instead of sorting the (metric, labels) view — and bounded to the last hour so it scans only recent chunks. Measured on docker-test: 540ms (old, view, full 2-day scan) → ~30ms. The 1h window also drops genuinely STALE series (removed containers' PSI, ended-flow eBPF histograms) that a live cockpit should not show; every polled vital/check reports far more often than hourly, so nothing live is lost.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/modules/sync`

Push the library's translated Starlark modules (or a given subset) to an enrolled host (Block G3), so it can EXECUTE them. Reads each module's .star + metadata sidecar from the library and delivers them over the existing mTLS channel; the agent validates, persists, and live-registers them. Requires a direct address (a proxy-only satellite → 409) and the agent's write gate open (the agent returns 403 otherwise, surfaced here).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `fqcns` (list of string, optional)

#### `GET /api/v1/agents/{agent_id}/parents`

L6: this host's reachability parents. A host that cannot be reached while ALL of its parents are down is UNREACHABLE rather than DOWN, and does not page.

In the path:

- `agent_id` (string, required)

#### `PUT /api/v1/agents/{agent_id}/parents`

Replaces the explicit parent list. A cycle is refused: a host that is (transitively) its own parent could never be judged, since "are all my parents down" would never terminate — and a self-parent would additionally excuse its own outage forever.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `parent_agent_ids` (list of string, required)

#### `POST /api/v1/agents/{agent_id}/poll-now`

Zabbix gap-analysis Block K5 ("Execute now"): force one agent to be polled immediately instead of waiting for the next settings.poll_interval_seconds tick — the same poll_agent the background loop uses (metrics/edges/hosts-overview pull, state evaluation, notification dispatch), just triggered on demand.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/service-control`

Block J2/J4a — safe service control. Restart/stop/start a systemd unit's running state, or enable/disable its start-at-boot state, on an enrolled host through the agent's idempotent `systemd` module (which is write-gated + ACL-checked + audited on the agent). No raw PID-kill (deliberate). A read-only agent (write=false) rejects it (surfaced as 502 from the agent's 403).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `action` (string, required)
- `service` (string, required)

#### `PATCH /api/v1/agents/{agent_id}/tags`

Block K7 (Zabbix gap-analysis, tagging): name or name:value host tags (empty-string value = name-only), inherited onto every problem this host raises (GET /api/v1/problems?tag=) and matchable by NotificationRule.tag_filter. Replaces the whole dict, matching update_agent_groups's replace-not-diff shape.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `tags` (object, required)

#### `POST /api/v1/agents/{agent_id}/update`

Push a new agent .deb to an ENROLLED host over the existing mTLS channel; the agent installs it (dpkg → postinst restart) and returns on the new version — the "Update" half of the deploy button. Works even for a write=false agent (the self-update carve-out). Requires a direct address + that the agent trusts Bossman's client cert (a satellite reachable only via its proxy has no direct address → 409; push it through its proxy or set an address).

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/update-bundled`

Push the package Bossman ships to an enrolled host — no upload needed. The right one is chosen by the host's OS family: RHEL/Fedora/SUSE get the .rpm (BOSSMAN_AGENT_RPM_PATH), everything else the .deb (BOSSMAN_AGENT_DEB_PATH). The agent installs whichever it receives (dpkg / rpm).

In the path:

- `agent_id` (string, required)

---

## monitoring

Check results as service states, with their history and their thresholds.

#### `GET /api/v1/agents/{agent_id}/effective-thresholds`

Checkmk's 'effective parameters' page, our way (Block E): for this host, every metric that has at least one applicable threshold rule, showing which rule WINS and why — plus the losing candidates and the reason each lost. OUR precedence is the reverse of Checkmk's: the closest-to-host rule wins (host > site > OU-deep > group > global) unless a higher one is enforced.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/services`

Every check result for one host, as service states.

One row per check assigned to this host: its state, its message, its metrics and when it last ran. A host that has just been enrolled legitimately returns an empty list — no checks are assigned yet, which is different from all checks passing.

404 when the agent id does not exist.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/services/{service_name}/availability`

Get Service Availability. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)
- `service_name` (string, required)

Query parameters:

- `hours` (number, optional, default `24.0`) — Look-back window in hours (default 24h)

#### `GET /api/v1/agents/{agent_id}/services/{service_name}/history`

Get Service History. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)
- `service_name` (string, required)

Query parameters:

- `limit` (whole number, optional, default `200`)

#### `GET /api/v1/check-rules`

Every check policy: which check is assigned where, with which parameters.

A rule is the *intension* — the declaration "hosts in this scope run this check with these thresholds". The service states it produces are the extension. Keep the two apart when reading this: a rule can exist while no host matches it, and that is not an error.

One rule can be linked to several OUs; both its primary scope and its additional OU links are folded into `ou_ids` here, deduplicated, so a caller does not have to join two tables to see a rule's real reach. For which rule actually *wins* on a given host — the precedence global < group < OU < site < host, with the reason — ask `GET /api/v1/agents/{agent_id}/effective-thresholds` instead.

#### `POST /api/v1/check-rules`

Assign a check to a scope with its parameters.

The scope is what makes this a policy rather than a per-host setting: global, a host group, an OU, a site or a single host. Overlapping rules are legitimate and resolved by precedence (global < group < OU < site < host) rather than rejected — a narrower scope is how an exception is expressed.

The parameters are validated against the check's own declared options, so a rule cannot carry a parameter the check would refuse. Nothing runs on a host until the assignment reaches it on the next cycle; the check is pushed to the agent and, if the agent rejects it, the resulting service says so rather than reporting a stale result.

The JSON body carries:

- `comparison` (string, required)
- `metric` (string, required)
- `service_name` (string, required)
- `condition_logic` (string, optional, default `"AND"`)
- `conditions` (object, optional, default `{}`)
- `crit_threshold` (number, optional)
- `depends_on_service_name` (string, optional)
- `enabled` (true or false, optional, default `true`)
- `enforced` (true or false, optional, default `false`)
- `extra_conditions` (list of object, optional)
- `label_value` (string, optional)
- `link_order` (whole number, optional, default `100`)
- `max_attempts` (whole number, optional)
- `recovery_threshold` (number, optional)
- `scope_ou_id` (string, optional)
- `scope_site_id` (string, optional)
- `scope_type` (string, optional, default `"global"`)
- `scope_value` (string, optional)
- `value_map_id` (string, optional)
- `warn_threshold` (number, optional)

#### `DELETE /api/v1/check-rules/{rule_id}`

Remove a check policy.

The check stops being assigned through this rule; hosts that matched it lose the service on the next cycle. Hosts that also match another rule keep it, with that rule's parameters — which may differ, so a delete can change thresholds rather than remove a check.

In the path:

- `rule_id` (string, required)

#### `PATCH /api/v1/check-rules/{rule_id}`

Change individual fields of a check policy; anything you omit stays as it is. This is the safe one for a partial edit — see PUT for why.

In the path:

- `rule_id` (string, required)

The JSON body carries:

- `enabled` (true or false, optional)
- `enforced` (true or false, optional)
- `link_order` (whole number, optional)
- `scope_ou_id` (string, optional)

#### `PUT /api/v1/check-rules/{rule_id}`

Replace a check policy wholesale.

Every field is taken from the body, so a field you omit is *cleared*, not kept — use PATCH when you mean to change one thing.

Note what this does *not* do: the `version` a rule carries in its representation is a content hash for change detection, and **nothing here checks it**. Two editors saving the same rule will not collide; the second write wins silently.

In the path:

- `rule_id` (string, required)

The JSON body carries:

- `comparison` (string, required)
- `metric` (string, required)
- `service_name` (string, required)
- `condition_logic` (string, optional, default `"AND"`)
- `conditions` (object, optional, default `{}`)
- `crit_threshold` (number, optional)
- `depends_on_service_name` (string, optional)
- `enabled` (true or false, optional, default `true`)
- `enforced` (true or false, optional, default `false`)
- `extra_conditions` (list of object, optional)
- `label_value` (string, optional)
- `link_order` (whole number, optional, default `100`)
- `max_attempts` (whole number, optional)
- `recovery_threshold` (number, optional)
- `scope_ou_id` (string, optional)
- `scope_site_id` (string, optional)
- `scope_type` (string, optional, default `"global"`)
- `scope_value` (string, optional)
- `value_map_id` (string, optional)
- `warn_threshold` (number, optional)

#### `POST /api/v1/check-rules/{rule_id}/ou-links`

Link a threshold policy to ANOTHER OU — one policy applies to many OUs (GPO-style multi-link) instead of being duplicated per OU. If the rule has no OU yet, the first linked OU becomes its primary scope; otherwise it's recorded in check_rule_ou_links. Idempotent.

In the path:

- `rule_id` (string, required)

The JSON body carries:

- `ou_id` (string, required)

#### `DELETE /api/v1/check-rules/{rule_id}/ou-links/{ou_id}`

Unlink a threshold policy from one OU. Removing the primary OU promotes another linked OU to primary (so an ou-scoped rule always keeps ≥1 OU); removing the last remaining OU is refused — delete the rule instead.

In the path:

- `rule_id` (string, required)
- `ou_id` (string, required)

#### `GET /api/v1/downtimes`

Planned outage windows: scheduled, past and running.

`active_only=true` narrows it to windows covering this moment, which is the set that is actually suppressing anything right now. Without `agent_id` you get the whole fleet's.

Query parameters:

- `agent_id` (string, optional)
- `active_only` (true or false, optional, default `false`) — Only downtimes whose window covers right now

#### `POST /api/v1/downtimes`

Declare a planned outage window, so what happens in it is not a problem.

A downtime covers one host (`agent_id`), optionally one `service_name` — omit it and the whole host is covered. During the window its services keep measuring and keep their real states; what changes is that they are left out of the problem list and the notification path.

422 when the window makes no sense (an end at or before its start); 404 when there is no such host. A downtime is not retroactive: a window in the past changes nothing about the notifications that already went out, because rewriting whether an alarm "should have" fired would falsify the record.

The JSON body carries:

- `agent_id` (string, required)
- `ends_at` (string, required)
- `starts_at` (string, required)
- `comment` (string, optional, default `""`)
- `service_name` (string, optional)

#### `DELETE /api/v1/downtimes/{downtime_id}`

Remove a downtime window. If it is running, its host's services return to the problem list immediately — with their current states, not the states they had when the window opened.

In the path:

- `downtime_id` (string, required)

#### `GET /api/v1/fleet/hosts`

The host-overview table's data source (see docs/plan.md's monitoring-cockpit ergänzung Block F2/F3): one row per host — every directly enrolled agent and every satellite discovered behind a proxy — with real CPU/memory/disk values and a CheckMK-style state rollup, in a single call instead of a per-host metrics fan-out.

Query parameters:

- `agent_id` (string, optional) — Return only this host's row

#### `GET /api/v1/fleet/summary`

The fleet in numbers: hosts by state, services by state, what needs attention.

The overview's top row, and read the axes carefully because they differ:

- **Hosts are counted by enrollment state**, not by health — pending, enrolled and the rest. A host's health is a rollup of its services, and this number is not that. - **Services are counted by monitoring state** across the four: OK, WARN, CRIT, UNKNOWN. - **Open problems** is the narrower number an operator acts on: non-OK, *not* acknowledged and *not* under a downtime. It is deliberately smaller than WARN + CRIT + UNKNOWN, and the difference is the work someone has already taken.

Every value is a count of rows that exist right now — not a rate, not an average.

#### `GET /api/v1/metric-catalog`

Every distinct metric actually collected across the fleet (from the `metrics` hypertable) with a human-readable display name — powers the threshold dialog's live metric search (Block L3c). The display name describes the METRIC (built-in map, then a titleized fallback), never a check-rule's service_name — a rule name like "... check" is about a rule, not the metric, and leaked the word "check" into the metric list.

#### `GET /api/v1/problems`

Everything currently not OK in the fleet — the problem list.

WARN, CRIT and UNKNOWN services, **most recently changed state first**, filterable by state, host name, acknowledgement and host tag. That ordering is deliberate: what just broke is what an operator has not seen yet.

**Services under an active downtime are excluded unless you ask for them** (`include_downtime=true`). That is the point of a downtime: a planned outage is not a problem, and a problem list that shows it teaches operators to ignore the list. They are excluded, never deleted — the service still has its state, and the downtime is why it is not here.

UNKNOWN is a state, not a gap: it means the check could not produce a verdict, and the service's message says why (no data yet, the check was refused, the check itself failed). Do not read it as OK.

Query parameters:

- `state` (string, optional) — Filter to one state: WARN|CRIT|UNKNOWN
- `host` (string, optional) — Filter to one host name
- `acknowledged` (true or false, optional) — Filter by acknowledged flag
- `include_downtime` (true or false, optional, default `false`) — Include services currently covered by a downtime
- `tag` (string, optional) — Filter by host tag: 'name' (any value) or 'name:value' (exact)

#### `POST /api/v1/services/acknowledge-bulk`

Acknowledge many problems at once (multi-select on the Problems table), the same mutation as the per-service route applied over a list — mirrors the mass_update_agent_groups bulk shape. Unknown ids are reported in `missing` rather than failing the whole batch.

The JSON body carries:

- `service_ids` (list of string, required)
- `comment` (string, optional, default `""`)
- `expire_after_minutes` (whole number, optional)

#### `DELETE /api/v1/services/{service_id}`

Delete one service row — for orphaned/stale services that no producer refreshes any more (a renamed check's leftover row like an old "Link state", or a service left behind after its assignment/rule was removed).

Deletes ONLY the `services` row (a small, plain table — a cheap normal DELETE). It deliberately does NOT touch `service_state_history`: that is a TimescaleDB hypertable, and deleting from a time-series hypertable forces its (potentially compressed) chunks to decompress and bloats the database. The stale timeline is harmless and its 30-day retention policy drops it on its own. Caveat: if an ACTIVE assignment, check rule, or agent builtin still materialises this service, the next poll recreates it — remove that producer first (unassign the check / delete the rule) to make the deletion stick.

In the path:

- `service_id` (string, required)

#### `DELETE /api/v1/services/{service_id}/acknowledge`

Take the acknowledgement back — the problem returns to the notification path with its comment and history intact. Used when whoever took it cannot finish it.

In the path:

- `service_id` (string, required)

#### `POST /api/v1/services/{service_id}/acknowledge`

Acknowledge a problem: someone has seen it and is dealing with it.

An acknowledgement does not change the state — the service stays CRIT, because it still is CRIT. It records that a human took it, with their name, their comment and the time, and it takes the service out of the notification path so the next escalation step does not fire. That separation is the point: suppressing the alarm must not be the same act as claiming the problem is gone.

`expire_after_minutes` makes it lapse by itself, which is what you want for "I'll look at this after lunch" — an acknowledgement that never expires is how a real problem gets forgotten.

It is also cleared automatically on the next **confirmed (hard) state change** — a recovery *or* a fresh problem onset. Both are new occurrences, and a stale acknowledgement carrying over into one would silence something nobody has looked at. A soft flicker does not clear it.

In the path:

- `service_id` (string, required)

The JSON body carries:

- `comment` (string, optional, default `""`)
- `expire_after_minutes` (whole number, optional)

---

## resources

Declared state: what a host is supposed to look like, and the plan/apply that gets it there.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `POST /api/v1/agents/{agent_id}/resources/config/apply`

Write the declared keys to the file — by merge, so foreign keys survive.

**`dry_run` defaults to `true`.** With `dry_run: false`, the agent parses the file, overlays exactly the keys in `values`, and serialises it back: keys nobody declared are left as they were, including comments where the codec preserves them. That is the whole point of the merge path — a whole-file render would silently destroy anything it did not know about.

A key set to `null` is *removed* rather than written empty, which is a different statement about the file and is why the value model allows it.

In the path:

- `agent_id` (string, required)

Query parameters:

- `path` (string, required)

The JSON body carries:

- `dry_run` (true or false, optional, default `true`)
- `format` (string, optional)
- `separator` (string, optional)
- `values` (object, optional, default `{}`)

#### `POST /api/v1/agents/{agent_id}/resources/config/plan`

What would change in this configuration file, key by key.

The file is addressed by `path` in the query string, not by a name segment — a filesystem path cannot ride in a URL segment unescaped. The body's `values` are the keys you want to declare; the plan shows them against what the host's file holds now.

Which of the two write paths applies is decided by the file's **codec**, not by the caller: a file this system can parse is written by merge, one it cannot is written by whole-file render from a template. Ask `GET /api/v1/config-fields?path=…` to find out which, along with the fields this file actually has.

In the path:

- `agent_id` (string, required)

Query parameters:

- `path` (string, required)

The JSON body carries:

- `format` (string, optional)
- `separator` (string, optional)
- `values` (object, optional, default `{}`)

#### `POST /api/v1/agents/{agent_id}/resources/config/rollback`

Restore this file to an earlier generation of declared values.

`generation` comes from `GET .../generations?path=…`. What is restored is the declaration, then re-merged — so keys the host gained from elsewhere in the meantime are still not touched.

Two limits worth knowing. Generations here are kept **without any retention limit**: nothing prunes `resource_generations`, so the table grows with every apply. (There *is* a 30-generation cap in this system, but it belongs to the separate docker desired-state model — `services/docker_desired.py`, pruned on discover — and it does not apply to this table. Do not assume one from the other.) And this endpoint always merges; the `exact` write mode the underlying `config` module offers (file holds exactly these keys, nothing else) is not reachable here, deliberately, because a resource whose rollback could delete undeclared keys would not be safe to roll back.

In the path:

- `agent_id` (string, required)

Query parameters:

- `path` (string, required)

The JSON body carries:

- `generation` (whole number, required)

#### `GET /api/v1/agents/{agent_id}/resources/config/{verb}`

`config`'s read verbs. Separate only because its instance is a filesystem path, which cannot ride in a URL segment unescaped — the reason is declared as `addressed_by='path'` in the registry rather than implied by this route existing.

In the path:

- `agent_id` (string, required)
- `verb` (string, required)

Query parameters:

- `path` (string, required)

#### `POST /api/v1/agents/{agent_id}/resources/docker/{name}/apply`

Bring the container to the spec in the body — and note the default.

**`dry_run` defaults to `true`.** A caller that omits it gets the plan and no change, which is the safe direction for a default to fail in, but it also means a naive "apply" reports success while having done nothing. Send `dry_run: false` when you mean it.

A successful non-dry apply records a **generation**: the spec that was applied, with the optional `note`. That is what `rollback` reverts to and what `GET .../generations` lists — the container is recreated from the spec rather than patched, so anything not in the spec is not preserved.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `dry_run` (true or false, optional, default `true`)
- `env` (object, optional, default `{}`)
- `image` (string, optional, default `""`)
- `note` (string, optional)
- `ports` (list of object, optional, default `[]`)
- `restart` (string, optional, default `"unless-stopped"`)
- `volumes` (list of string, optional, default `[]`)

#### `POST /api/v1/agents/{agent_id}/resources/docker/{name}/plan`

What would change about this container, without touching it.

Returns the diff between the container as it runs now and the spec in the body: image, published ports, environment, volumes, restart policy. Nothing is written, so this is safe to call on anything at any time — and it is the call to make before `apply`, because a plan is reviewable and an apply is not.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `env` (object, optional, default `{}`)
- `image` (string, optional, default `""`)
- `ports` (list of object, optional, default `[]`)
- `restart` (string, optional, default `"unless-stopped"`)
- `volumes` (list of string, optional, default `[]`)

#### `POST /api/v1/agents/{agent_id}/resources/docker/{name}/rollback`

Recreate the container from an earlier generation's spec.

`generation` is a number from `GET .../generations`. This is a real revert, not a forward-converge: the stored spec is applied as it was. What it cannot restore is anything that was never part of the spec — data in an anonymous volume, or a manual `docker exec` change — because a generation records the declaration, not the container's contents.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `generation` (whole number, required)

#### `POST /api/v1/agents/{agent_id}/resources/helm/{name}/apply`

Install or upgrade the release to the chart and values in the body.

**`dry_run` defaults to `true`** here too — see `docker_apply` for why that matters. A non-dry apply records a generation (chart + values + note), which is what `rollback` targets. Helm keeps its own revision history as well; the generation recorded here is Bossman's, and the two are not the same numbering.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

Query parameters:

- `namespace` (string, optional, default `"default"`)

The JSON body carries:

- `chart` (string, optional, default `""`)
- `dry_run` (true or false, optional, default `true`)
- `note` (string, optional)
- `values` (object, optional, default `{}`)

#### `POST /api/v1/agents/{agent_id}/resources/helm/{name}/plan`

What this release would become: the chart and values in the body against the release as installed. Reads only. `namespace` defaults to `default`.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

Query parameters:

- `namespace` (string, optional, default `"default"`)

The JSON body carries:

- `chart` (string, optional, default `""`)
- `values` (object, optional, default `{}`)

#### `POST /api/v1/agents/{agent_id}/resources/helm/{name}/rollback`

Re-apply an earlier generation's chart and values. `generation` comes from `GET .../generations` — it is Bossman's number, not Helm's revision.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

Query parameters:

- `namespace` (string, optional, default `"default"`)

The JSON body carries:

- `generation` (whole number, required)

#### `POST /api/v1/agents/{agent_id}/resources/package/{name}/apply`

Install, remove or upgrade the package. **`dry_run` defaults to `true`.**

Reaches the host's own package manager through the `package` module, so it is idempotent for `present` and `absent`: applying twice equals applying once, and the response says `changed: false` when nothing had to happen. A generation is recorded so `rollback` can restore the previous declared state — that restores the *declaration* (`present`/`absent`/version), not the exact binary contents of a repository that has moved on.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `dry_run` (true or false, optional, default `true`)
- `note` (string, optional)
- `state` (string, optional, default `"present"`)

#### `POST /api/v1/agents/{agent_id}/resources/package/{name}/plan`

What installing, removing or upgrading this package would do on this host.

`state` is `present`, `absent` or `latest`. `latest` is not idempotent in the way the other two are — it means "whatever the repository currently offers", so it can change on a host that nobody touched, and a plan for it is only true for as long as the repository stays put.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `state` (string, optional, default `"present"`)

#### `POST /api/v1/agents/{agent_id}/resources/package/{name}/rollback`

Re-apply this package's previous declared state from `GET .../generations`. Restores the declaration, not a snapshot: if the repository now offers a different version, `present` will install that one.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `generation` (whole number, required)

#### `POST /api/v1/agents/{agent_id}/resources/role/{name}/apply`

Bind this role to the host — desired state, not an immediate run.

A role is an OrchestrationPlan of type `role`; binding it means the host is *supposed* to have it, and the binding converges when the host next checks in. That is why this works on a host with no address at all, including a bare-metal machine that has not booted yet: the binding is database state.

Two defaults to know. **`dry_run` defaults to `true`**, so an apply that omits it changes nothing. And **`require_approval` defaults to `true`**: the binding is created `pending_approval` and does nothing until someone approves it, unless approval is waived here or global YOLO mode is on. The gate is deliberate — see the remediation guardrails for the same pattern.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `dry_run` (true or false, optional, default `true`)
- `note` (string, optional)
- `parameters` (object, optional, default `{}`)
- `require_approval` (true or false, optional, default `true`)

#### `DELETE /api/v1/agents/{agent_id}/resources/role/{name}/binding`

Remove this host's direct binding of the role (the counterpart of apply) and recompile the host's desired state. Inherited bindings (OU/group) are untouched — unbind those at their own scope.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

#### `POST /api/v1/agents/{agent_id}/resources/role/{name}/plan`

Check-mode run: the steps that WOULD change (no writes).

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `parameters` (object, optional, default `{}`)

#### `POST /api/v1/agents/{agent_id}/resources/role/{name}/rollback`

Re-run the role with an earlier parameter set (forward-converge; only truly reverts if the role's steps are idempotent — the response says so).

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `generation` (whole number, required)

#### `POST /api/v1/agents/{agent_id}/resources/service/{name}/apply`

Set the service's boot-enablement and/or run state. **`dry_run` defaults to `true`.**

`enabled` and `state` are separate declarations and either may be omitted: a unit can legitimately be enabled and stopped, or running and disabled, and this endpoint will not quietly make them agree. Note that `restarted` and `reloaded` are *actions*, not states — they are never idempotent, and the response reports `changed: true` every time because that is what happened.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `dry_run` (true or false, optional, default `true`)
- `enabled` (true or false, optional)
- `note` (string, optional)
- `state` (string, optional)

#### `POST /api/v1/agents/{agent_id}/resources/service/{name}/plan`

What would change about this service unit: whether it is enabled at boot (`enabled`) and whether it is running (`state`: started, stopped, restarted, reloaded). Only the fields you send are considered — the two are independent, and a plan that assumed the missing one would be inventing a declaration.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `enabled` (true or false, optional)
- `state` (string, optional)

#### `POST /api/v1/agents/{agent_id}/resources/service/{name}/rollback`

Re-apply this unit's previous declared enablement and run state from `GET .../generations`. A rollback of `restarted` re-runs the restart, since there is no earlier state to return to — the response says so.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

The JSON body carries:

- `generation` (whole number, required)

#### `GET /api/v1/agents/{agent_id}/resources/{kind}/{name}/{verb}`

The READ half of the four-verb contract, for every kind — `schema`, `observe` and `generations`.

This used to be seventeen near-identical routes (six kinds x three verbs, minus config's missing schema). The paths are unchanged; what changed is that the per-kind differences now come from `services/resources`' registry instead of from copies: which schema method a kind has, whether it needs a reachable host, whether its observe carries a schema, whether its history has a scope. See docs/logik-audit.md area 7 for why the duplication was the actual defect.

`config` is addressed by a filesystem path rather than a name segment, so it has its own route below.

In the path:

- `agent_id` (string, required)
- `kind` (string, required)
- `name` (string, required)
- `verb` (string, required)

Query parameters:

- `namespace` (string, optional, default `"default"`)

#### `GET /api/v1/resource-kinds`

What kinds exist and how each one behaves — the registry as plain data.

The UI used to hard-code this and got it wrong: it built a `/schema` URL for every kind including `config`, which has no such endpoint (docs/logik-audit.md area 7). Deriving the capabilities from here means the client cannot disagree with the server about what a kind can do — there is one source of truth, and it is the one the routes themselves use.

---

## orchestration

Runbooks in flight: starting one, watching its steps, and the results per host.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/agents/{agent_id}/desired-state`

What this host is *supposed* to look like: the compiled desired state.

The result of folding every plan link, template link, policy and threshold that reaches this host, in precedence order, into one document. This is the **rule** side; what the host actually looks like is the observed state, read elsewhere. Keeping the two apart is the point — a screen that mixed them could not answer "is this host converged".

Always current: creating, approving or deleting a link recompiles the affected hosts before returning, so this never serves a state that is one cycle behind.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/desired-state/diff`

Leaf-level diff of the host's desired_state between two generations (default: previous → current) — what config/variable/threshold/role changed.

In the path:

- `agent_id` (string, required)

Query parameters:

- `from_gen` (whole number, optional)
- `to_gen` (whole number, optional)

#### `GET /api/v1/agents/{agent_id}/desired-state/generations`

The host's compiled desired-state generation history (Bossman-side), newest first — the time machine's index.

In the path:

- `agent_id` (string, required)

#### `DELETE /api/v1/orchestration/links/{link_id}`

Delete a plan link by its id alone (Block L3c) — the OU-tree console deletes an orchestration-link object without needing its plan id.

In the path:

- `link_id` (string, required)

#### `GET /api/v1/orchestration/pending-links`

Every link awaiting human approval, tenant-wide — the review queue an admin (or the MCP list_pending_orchestration_links tool, read-only) checks before deciding what to approve/reject.

#### `GET /api/v1/orchestration/plans`

Every orchestration plan — and note which kind of "plan" this is.

This API has **two unrelated things called a plan**, and confusing them is the most likely mistake here:

- **An orchestration plan (this one)** is *desired state*: a stable named handle (`docker_host`, `postgres_cluster`) whose content lives in immutable versions and which takes effect by being **linked** to a scope. Nothing runs when you create one. Types: role, cluster, deployment, remediation, maintenance, bootstrap. - **A runbook plan (`GET /api/v1/plans`)** is a step list you *execute* against a host — "take plan X, run it against host Y". That one has a `/run`.

Soft-deleted plans are excluded; the deletion is recorded, not erased.

#### `POST /api/v1/orchestration/plans`

Create the named handle. It does nothing until it has content and a link.

`plan_type` must be one of role, cluster, deployment, remediation, maintenance, bootstrap (422 otherwise), and the name must be unique (409). What a plan *does* lives in its versions — `POST .../versions` — and *where* it applies lives in its links. A plan with neither is inert on purpose: it exists so a link can point at a name that will not change when the content does.

The JSON body carries:

- `display_name` (string, required)
- `name` (string, required)
- `plan_type` (string, required)
- `description` (string, optional, default `""`)
- `version` (object, optional) — PlanVersionIn

#### `DELETE /api/v1/orchestration/plans/{plan_id}`

Delete a plan, its versions and its links, then recompile.

The links go with it (`ON DELETE CASCADE`), so every host that had this plan through any scope loses it — which is a change to those hosts' desired state, and the tenant is recompiled immediately rather than at the next cycle so `GET .../desired-state` never shows a plan that no longer exists.

This is not reversible through the API. To stop a plan applying somewhere without losing it, delete the **link** instead.

In the path:

- `plan_id` (string, required)

#### `GET /api/v1/orchestration/plans/{plan_id}`

One orchestration plan with its current version pointer and its links. 404 when there is no such id or it has been deleted.

In the path:

- `plan_id` (string, required)

#### `PATCH /api/v1/orchestration/plans/{plan_id}`

Rename or re-describe a plan. **Metadata only, deliberately.**

This endpoint cannot touch the plan's versions or entries. Editing a label is the most common reason to open a policy, and if that same call could carry content, a client that sent a partial body would silently drop the plan's steps. Content changes go through `POST .../versions`, which adds a new immutable version.

In the path:

- `plan_id` (string, required)

The JSON body carries:

- `description` (string, optional)
- `display_name` (string, optional)

#### `GET /api/v1/orchestration/plans/{plan_id}/links`

Where this plan applies: one row per scope it is linked to.

A link carries its own status — `active`, `pending_approval` or `rejected` — so this is also the answer to "why is this plan not on that host": the link may exist and be waiting for approval. Both are shown; a pending link is not hidden, because an invisible pending change is indistinguishable from no change at all.

In the path:

- `plan_id` (string, required)

#### `POST /api/v1/orchestration/plans/{plan_id}/links`

Block L2 approval gate: a link is created `active` immediately only if the global YOLO-MAN switch is on, or the link itself opts in via auto_apply / require_approval=false — otherwise it starts `pending_approval` and has no effect until POST .../approve. This is the one and only place that decides a link's initial status; the MCP write tool calls this same endpoint's underlying logic and can never pass auto_apply=true (see mcp/server.py).

In the path:

- `plan_id` (string, required)

The JSON body carries:

- `target_type` (string, required)
- `agent_id` (string, optional)
- `auto_apply` (true or false, optional, default `false`)
- `enforced` (true or false, optional, default `false`)
- `host_group_id` (string, optional)
- `link_order` (whole number, optional, default `100`)
- `ou_id` (string, optional)
- `parameters` (object, optional, default `{}`)
- `plan_version` (whole number, optional)
- `priority` (whole number, optional, default `100`)
- `require_approval` (true or false, optional, default `true`)
- `site_id` (string, optional)

#### `DELETE /api/v1/orchestration/plans/{plan_id}/links/{link_id}`

Unlink the plan from this scope and recompile the affected hosts.

The plan itself survives; only this binding goes. Hosts that also receive the plan through another scope keep it — so a delete here can change nothing at all, and the recompile is what tells you which it was.

In the path:

- `plan_id` (string, required)
- `link_id` (string, required)

#### `POST /api/v1/orchestration/plans/{plan_id}/links/{link_id}/approve`

Approve a pending link — the moment desired state actually starts applying.

Sets the link `active` and **immediately recompiles every affected host**, so the change is visible in `GET .../desired-state` before this call returns rather than at the next cycle.

**409 when the link is not `pending_approval`.** Approving an already-active link is not a harmless no-op question — it means the caller believes something is waiting that is not, and answering "fine" would confirm a wrong belief.

In the path:

- `plan_id` (string, required)
- `link_id` (string, required)

#### `POST /api/v1/orchestration/plans/{plan_id}/links/{link_id}/reject`

Reject a pending link: it stays as a `rejected` row and applies to nothing.

Rejected rather than deleted, on purpose — "someone decided against this" is a fact worth keeping, and a link that vanished would leave the next person to propose the same thing with no idea it had already been refused.

409 when the link is not `pending_approval`, for the same reason as approve.

In the path:

- `plan_id` (string, required)
- `link_id` (string, required)

#### `POST /api/v1/orchestration/plans/{plan_id}/preview-link`

The safe "what would this link do" primitive (Block L2) — computes blast radius + a sample before/after monitoring diff WITHOUT persisting anything. Same underlying compiler.preview_plan_link the MCP dry-run tool calls.

In the path:

- `plan_id` (string, required)

The JSON body carries:

- `target_type` (string, required)
- `agent_id` (string, optional)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `parameters` (object, optional, default `{}`)
- `plan_version` (whole number, optional)
- `site_id` (string, optional)

#### `POST /api/v1/orchestration/plans/{plan_id}/versions`

Adds a new immutable version and makes it current — every host with a link that follows current_version (plan_version=NULL) picks it up on the next recompile, which this triggers immediately.

In the path:

- `plan_id` (string, required)

The JSON body carries:

- `default_parameters` (object, optional, default `{}`)
- `generated_monitoring` (object, optional, default `{}`)
- `generated_notifications` (object, optional, default `{}`)
- `parameter_schema` (object, optional, default `{}`)
- `requirements` (object, optional, default `{}`)
- `rollback_steps` (list of string, optional, default `[]`)
- `steps` (list of string, optional, default `[]`)
- `validation_steps` (list of string, optional, default `[]`)

---

## chat

The natural-language interface over the fleet, and the tools it is allowed to call.

#### `GET /api/v1/chat/backends`

The selectable AI backends + the configured default — powers the UI's backend selector.

#### `GET /api/v1/chat/dashboard`

Get Generated Dashboard. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/chat/dashboard/generate`

Have the configured AI design a dashboard (it may call fleet tools for real data) and persist it for this user. Enabled once a backend is usable.

The JSON body carries:

- `backend` (string, optional)
- `prompt` (string, optional, default `""`)

#### `POST /api/v1/chat/oauth/claude/complete`

Claude Complete. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `code` (string, required)
- `session_id` (string, required)

#### `POST /api/v1/chat/oauth/claude/start`

Claude Start. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/chat/oauth/codex/poll/{session_id}`

Codex Poll. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `session_id` (string, required)

#### `POST /api/v1/chat/oauth/codex/start`

Codex Start. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `GET /api/v1/chat/oauth/status`

Which backends this user is logged in for. hermes_web is server-side (no per-user login).

#### `GET /api/v1/chat/prefs`

Get Prefs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `PATCH /api/v1/chat/prefs`

Set Prefs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `default_backend` (string, optional)
- `hermes_base_url` (string, optional)
- `hermes_model` (string, optional)
- `models` (object, optional)

#### `GET /api/v1/chat/sessions`

List Sessions. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/chat/sessions`

Create Session. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `backend` (string, optional)
- `label` (string, optional)

#### `DELETE /api/v1/chat/sessions/{sid}`

Delete Session. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `sid` (string, required)

#### `PATCH /api/v1/chat/sessions/{sid}`

Rename Session. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `sid` (string, required)

The JSON body carries:

- `label` (string, required)

#### `GET /api/v1/chat/sessions/{sid}/history`

Session History. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `sid` (string, required)

#### `POST /api/v1/chat/sessions/{sid}/message`

Send Message. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `sid` (string, required)

The JSON body carries:

- `content` (string, required)
- `backend` (string, optional)

---

## plans

A plan is a proposed change with its diff, kept so it can be reviewed before it is applied.

#### `GET /api/v1/plan-library`

Every stored plan/role (latest version) with its folder placement, for the plan-library tree. Un-placed plans report folder "" (root).

#### `GET /api/v1/plans`

List Plans. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/plans/import-bulk`

Import a whole directory of foreign orchestration sources — Ansible, Salt, Puppet, Chef — in one call.

A checked-out role/cookbook tree is mostly NOT plans (templates, defaults, metadata, fixtures), so each file is classified first (services/plan_store.detect_plan_format) and anything unrecognised is SKIPPED with a reason instead of failing the import. One unparseable file likewise lands in `failed` and the rest still import — a 400-file tree must not be lost because file 3 is exotic.

`dry_run` classifies without writing, so the operator can see what a tree would produce first.

The JSON body carries:

- `files` (list of object, required)
- `dry_run` (true or false, optional, default `false`)
- `folder` (string, optional, default `""`)

#### `POST /api/v1/plans/reload`

Re-imports plans_dir into the canonical store (docs/zielbestimmung.md #5 — keeping the store in sync with the authoring dir) and re-renders the MCP facade's static plan-catalog text from disk. Anthropic prompt caching needs that text byte-identical across calls, so it is never re-rendered per request, only on this explicit operator action.

#### `POST /api/v1/plans/search`

Embedding-based retrieval over the plan catalog (see docs/plan.md's "Plan-catalog RAG") — an alternative to scanning the full catalog_markdown/list_plans dump once the catalog grows past a handful of plans. Re-indexes any plan whose description changed since the last call (cheap after the first time, via index_plan_catalog's own content-hash short-circuit) before searching, so this route never needs a separate "reindex" step.

The JSON body carries:

- `query` (string, required)
- `threshold` (number, optional)
- `top_k` (whole number, optional, default `5`)

#### `GET /api/v1/plans/stored`

List Stored Plans. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `prefix` (string, optional)

#### `POST /api/v1/plans/stored`

Create Stored Plan. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `prefix` (string, required)
- `source_format` (string, required)
- `source_text` (string, required)

#### `DELETE /api/v1/plans/stored/{prefix}/{name}`

Delete a stored plan (all versions + its folder placement).

In the path:

- `prefix` (string, required)
- `name` (string, required)

#### `GET /api/v1/plans/stored/{prefix}/{name}/document`

A stored plan version rendered as YAML + JSON from the one canonical JSON body, so the editor's format toggle is instant. Defaults to the latest version; `version` selects an older one (for diffing). Also returns source_text + source_format + folder.

In the path:

- `prefix` (string, required)
- `name` (string, required)

Query parameters:

- `version` (whole number, optional)

#### `POST /api/v1/plans/stored/{prefix}/{name}/move`

Place a plan/role into a folder path (creates the folder implicitly).

In the path:

- `prefix` (string, required)
- `name` (string, required)

The JSON body carries:

- `folder` (string, required)

#### `POST /api/v1/plans/stored/{prefix}/{name}/run`

Run a plan from the canonical store (any prefix) against a host — the store counterpart of POST /api/v1/plans/{name}/run.

In the path:

- `prefix` (string, required)
- `name` (string, required)

The JSON body carries:

- `agent` (string, required)
- `dry_run` (true or false, optional, default `false`)
- `params` (object, optional, default `{}`)

#### `GET /api/v1/plans/stored/{prefix}/{name}/versions`

Every stored version of a plan (newest first) for the diff/version picker.

In the path:

- `prefix` (string, required)
- `name` (string, required)

#### `GET /api/v1/plans/{name}`

Get Plan. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `name` (string, required)

#### `POST /api/v1/plans/{name}/briefing`

Plan Briefing. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `name` (string, required)

#### `POST /api/v1/plans/{name}/run`

Run Plan Route. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `name` (string, required)

The JSON body carries:

- `agent` (string, required)
- `dry_run` (true or false, optional, default `false`)
- `params` (object, optional, default `{}`)

---

## remediation

Closed-loop repair: a proposal, its guardrails, its autonomy setting, and its rollback.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `POST /api/v1/agents/{agent_id}/trigger-event-rules`

Manually run the remediation policies matching (host, check) now — bypasses the rate limit (an operator/AI-initiated heal).

In the path:

- `agent_id` (string, required)

Query parameters:

- `service` (string, required)

#### `GET /api/v1/event-handlers`

List Event Handlers. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/event-handlers`

Create Event Handler. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `body` (string, optional, default `"script"`)
- `description` (string, optional, default `""`)
- `enabled` (true or false, optional, default `true`)
- `interpreter` (string, optional)
- `local_name` (string, optional)
- `location` (string, optional, default `"managed"`)
- `parameters` (list of object, optional, default `[]`)
- `runbook_name` (string, optional)
- `source` (string, optional)
- `timeout_s` (whole number, optional, default `300`)

#### `GET /api/v1/event-handlers/meta`

Event Handler Meta. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `DELETE /api/v1/event-handlers/{handler_id}`

Delete Event Handler. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `handler_id` (string, required)

#### `GET /api/v1/event-handlers/{handler_id}`

Get Event Handler. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `handler_id` (string, required)

#### `PUT /api/v1/event-handlers/{handler_id}`

Update Event Handler. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `handler_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `body` (string, optional, default `"script"`)
- `description` (string, optional, default `""`)
- `enabled` (true or false, optional, default `true`)
- `interpreter` (string, optional)
- `local_name` (string, optional)
- `location` (string, optional, default `"managed"`)
- `parameters` (list of object, optional, default `[]`)
- `runbook_name` (string, optional)
- `source` (string, optional)
- `timeout_s` (whole number, optional, default `300`)

#### `GET /api/v1/event-handlers/{handler_id}/availability`

Is this handler's file actually on the hosts?

Only meaningful for `location=local`: a managed script is deployed by the run itself, and a runbook lives in this database. For a local one the body is outside Bossman, so without this check "the handler will run" is a claim nobody has tested until the event fires.

A host that cannot be reached is reported as `unreachable`, not as `missing`: treating the two alike would tell the operator to install a file that may well already be there.

In the path:

- `handler_id` (string, required)

Query parameters:

- `agent_ids` (list of string, optional, default `[]`) — Hosts to check; omit for every host with an address

#### `GET /api/v1/event-rules`

List Remediation Policies. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/event-rules`

Create Remediation Policy. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `agent_id` (string, optional)
- `allow_prod` (true or false, optional, default `false`)
- `autonomy` (string, optional, default `"propose"`)
- `conditions` (object, optional, default `{}`)
- `enabled` (true or false, optional, default `true`)
- `event_handler_id` (string, optional)
- `host_group_id` (string, optional)
- `match_service_name` (string, optional, default `""`)
- `max_blast_radius` (whole number, optional, default `1`)
- `max_per_hour` (whole number, optional, default `3`)
- `mode` (string, optional, default `"auto"`)
- `ou_id` (string, optional)
- `params` (object, optional, default `{}`)
- `rollback_runbook` (string, optional)
- `runbook_name` (string, optional, default `""`)
- `scope_type` (string, optional, default `"global"`)
- `verify` (true or false, optional, default `true`)
- `verify_after_s` (whole number, optional, default `60`)

#### `DELETE /api/v1/event-rules/{policy_id}`

Delete Remediation Policy. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `policy_id` (string, required)

#### `PUT /api/v1/event-rules/{policy_id}`

Edit a rule in place.

This did not exist, so "editing" a rule meant deleting and recreating it — and because remediation_runs.policy_id is ON DELETE SET NULL, that silently cut every past run loose from the rule that caused it. The audit trail would still list the runs and no longer be able to say why they happened.

In the path:

- `policy_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `agent_id` (string, optional)
- `allow_prod` (true or false, optional, default `false`)
- `autonomy` (string, optional, default `"propose"`)
- `conditions` (object, optional, default `{}`)
- `enabled` (true or false, optional, default `true`)
- `event_handler_id` (string, optional)
- `host_group_id` (string, optional)
- `match_service_name` (string, optional, default `""`)
- `max_blast_radius` (whole number, optional, default `1`)
- `max_per_hour` (whole number, optional, default `3`)
- `mode` (string, optional, default `"auto"`)
- `ou_id` (string, optional)
- `params` (object, optional, default `{}`)
- `rollback_runbook` (string, optional)
- `runbook_name` (string, optional, default `""`)
- `scope_type` (string, optional, default `"global"`)
- `verify` (true or false, optional, default `true`)
- `verify_after_s` (whole number, optional, default `60`)

#### `GET /api/v1/event-runs`

Remediation history + the pending-proposal queue (?status=pending).

Query parameters:

- `status` (string, optional)
- `limit` (whole number, optional, default `100`)

#### `POST /api/v1/event-runs/{run_id}/apply`

Apply a PENDING remediation proposal now — the manual "Apply" action. Self-healing never runs automatically; this is the only execution path (besides the direct /remediate trigger).

In the path:

- `run_id` (string, required)

#### `POST /api/v1/event-runs/{run_id}/dismiss`

Dismiss a pending proposal without running it.

In the path:

- `run_id` (string, required)

---

## blueprints

A reusable bundle of declared state that can be applied to a new host.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/blueprints`

List Blueprints. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/blueprints`

Create Blueprint. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)
- `path` (string, optional, default `""`)
- `services` (list of string, optional, default `[]`)
- `status` (string, optional, default `"draft"`)

#### `POST /api/v1/blueprints/plausibility`

Validate an in-flight draft (not yet saved): every requirement resolved (in-blueprint or a fleet host), every connection field supplied.

The JSON body carries:

- `services` (list of string, optional, default `[]`)

#### `POST /api/v1/blueprints/provision`

Out-of-band credential provisioning (step 4 of the designer, secret-safe): create the DB+user on the provider via the agent `command` module, then store the password for the consumer as a vault handle in its host_vars. No plaintext is persisted and no agent module is required.

The JSON body carries:

- `admin_password` (string, required)
- `admin_user` (string, required)
- `consumer_agent_id` (string, required)
- `db_name` (string, required)
- `db_user` (string, required)
- `provider_agent_id` (string, required)
- `backend` (string, optional, default `"mysql"`)
- `container` (string, optional)
- `exec` (string, optional, default `"local"`)
- `existing_agent_id` (string, optional)
- `existing_host_group_id` (string, optional)
- `existing_key` (string, optional)
- `existing_ou_id` (string, optional)
- `existing_scope_type` (string, optional)
- `password` (string, optional, default `""`)
- `password_mode` (string, optional, default `"generate"`)
- `targets` (object, optional, default `{}`)

#### `POST /api/v1/blueprints/seed-drafts`

Install the sample blueprint drafts (idempotent).

#### `POST /api/v1/blueprints/suggest-providers`

For an in-flight draft, per open requirement: matching fleet hosts + candidate roles a new server would need. Drives step 2 of the designer live.

The JSON body carries:

- `services` (list of string, optional, default `[]`)

#### `DELETE /api/v1/blueprints/{bp_id}`

Delete Blueprint. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `bp_id` (string, required)

#### `GET /api/v1/blueprints/{bp_id}`

Get Blueprint. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `bp_id` (string, required)

#### `PUT /api/v1/blueprints/{bp_id}`

Update Blueprint. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `bp_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)
- `path` (string, optional, default `""`)
- `services` (list of string, optional, default `[]`)
- `status` (string, optional, default `"draft"`)

#### `POST /api/v1/blueprints/{bp_id}/bind-to-scope`

Compile the blueprint and bind it to an OU / Site / host-group / host as a `deployment` orchestration plan. The desired-state compiler then folds the stack into every host in that scope — so a freshly PXE-provisioned host that lands in the OU/Site comes up running the blueprint automatically, with no per-host step. Idempotent on the plan name: re-binding adds a new plan version. Honours the L2 approval gate (starts pending_approval unless YOLO / auto_apply).

In the path:

- `bp_id` (string, required)

The JSON body carries:

- `target_type` (string, required)
- `agent_id` (string, optional)
- `auto_apply` (true or false, optional, default `false`)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `require_approval` (true or false, optional, default `true`)
- `site_id` (string, optional)

#### `GET /api/v1/blueprints/{bp_id}/compile`

Compile the blueprint into a typed playbook + wiring/order report. Resolves requirements against the fleet too, and MASKS secret values in this preview.

In the path:

- `bp_id` (string, required)

#### `GET /api/v1/blueprints/{bp_id}/plausibility`

Design-time validation: does every requirement resolve (in-blueprint or on a real fleet host), and is every connection field supplied? Returns {ok, problems[], wiring, unresolved, order}.

In the path:

- `bp_id` (string, required)

#### `POST /api/v1/blueprints/{bp_id}/save-as-runbook`

Compile the blueprint and persist the typed playbook as a Runbook, so the stack can be run (run-runbook), bound to a scope (orchestration link), or delivered as a PXE target_runbook at boot. Idempotent on the runbook name.

In the path:

- `bp_id` (string, required)

#### `GET /api/v1/blueprints/{bp_id}/suggest-providers`

For each requirement that no in-blueprint service satisfies, propose how to fill it: existing fleet hosts that provide it, plus the catalog roles a NEW server would need. Drives step 2 of the designer ("find a matching provider").

In the path:

- `bp_id` (string, required)

---

## checks

The check catalogue: what can be measured, and which hosts a check is assigned to.

#### `GET /api/v1/agents/{agent_id}/checks`

The checks that effectively apply to this host — resolved GPO-style from every assignment reaching it (host + groups + OU ancestry), with merged params and the winning scope. Each entry is enriched with the check's short_description + options (the config form's argspec).

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/checks/{name}/provision`

Run the check's provisioning recipe on the host (create the monitoring account with the operator-supplied admin creds), then assign the check to the host with the generated monitoring credential. Admin creds are used only for the setup command and never stored. Needs manage rights on the host. body: {admin_params: {...}, extra_params?: {...}}.

In the path:

- `agent_id` (string, required)
- `name` (string, required)

Takes a free-form JSON object as its body.

#### `POST /api/v1/agents/{agent_id}/discover`

Start Checkmk-style auto-discovery as a BACKGROUND JOB and return its id + total.

Discovery probes ~1400 checks and takes seconds, so it no longer blocks the request: it returns {job_id, total, candidates} immediately, and the UI polls GET .../discover/progress/{job_id} for a percent bar and, on completion, the result (proposals + transitions — Checkmk's QualifiedDiscovery, which reconciles against what was found last time so a LOST service is distinguishable from one that never existed). It still decides nothing: new → undecided, missing → vanished; accept/ignore via .../discover/apply.

Optional body: {check_names:[...]} scopes the run (no reconcile — it saw only a slice), {datasource: 'snmp'} for a device.

In the path:

- `agent_id` (string, required)

Takes a free-form JSON object as its body.

#### `POST /api/v1/agents/{agent_id}/discover/apply`

Decide what to do with discovered services.

body {accept|ignore|remove: [{check_name, item?, parameters?}, ...]} accept -> discovered_services.state='monitored' + a host-scoped CheckAssignment ignore -> state='ignored'; later runs stop offering it (the decision is REMEMBERED, which is the whole point — previously, not applying left no trace) remove -> drop the assignment and reset the row to 'undecided'

`assign` is still accepted as an alias for `accept`, so the existing UI and the AI chat tool keep working unchanged.

IDEMPOTENT: accepting twice does not create a second assignment. The old version inserted unconditionally, so a repeated apply silently duplicated every row — Checkmk's set_autochecks rewrites the host's set and de-duplicates by identity (cmk/checkengine/discovery/_autochecks.py).

In the path:

- `agent_id` (string, required)

Takes a free-form JSON object as its body.

#### `GET /api/v1/agents/{agent_id}/discover/progress/{job_id}`

Poll a discovery job's progress: {total, completed, percent, done, result?/error?}.

The result (host services) is only readable by someone who may manage the host, same as starting the discovery.

In the path:

- `agent_id` (string, required)
- `job_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/discovered-services`

What discovery knows about this host, by lifecycle state.

This is the persisted discovery result (Checkmk's autochecks), NOT the monitoring state — a row here says "this service exists on the host", while services.state says OK/WARN/CRIT. Optional ?state= filters to one of undecided|monitored|vanished|ignored.

In the path:

- `agent_id` (string, required)

Query parameters:

- `state` (string, optional)

#### `GET /api/v1/agents/{agent_id}/host-labels`

This host's Checkmk-style labels, with where each came from.

Distinct from Agent.tags (our host tags) and from metric-series labels.

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/check-assignments`

Raw check assignments, optionally filtered to one scope target — the direct assignments on a host / group / OU (not the resolved inheritance; use GET /agents/{id}/checks for the effective set).

Query parameters:

- `agent_id` (string, optional)
- `ou_id` (string, optional)
- `host_group_id` (string, optional)

#### `POST /api/v1/check-assignments`

Assign a check to a host, group, or OU with per-scope parameters. A host-scoped assignment needs manage rights on that host; group/OU-scoped assignments are admin-only (they affect many hosts). The check must exist in the library.

The JSON body carries:

- `check_name` (string, required)
- `scope_type` (string, required)
- `agent_id` (string, optional)
- `conditions` (object, optional, default `{}`)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `parameters` (object, optional, default `{}`)
- `source` (string, optional, default `"manual"`)

#### `DELETE /api/v1/check-assignments/{assignment_id}`

Delete Assignment. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `assignment_id` (string, required)

#### `PATCH /api/v1/check-assignments/{assignment_id}`

Edit an existing assignment's parameters in place (same scope/check), so a service check can be reconfigured without delete+recreate. Same ACL as delete: host scope → manage that host; group/OU → admin.

In the path:

- `assignment_id` (string, required)

The JSON body carries:

- `parameters` (object, required)

#### `GET /api/v1/checks`

Every check in the library: name, short_description, source (translated|custom), and its options (the argspec the host-page config form renders).

#### `GET /api/v1/checks/{name}`

One check's stored metadata + Starlark source.

In the path:

- `name` (string, required)

#### `GET /api/v1/checks/{name}/provisioning`

Whether this check ships a provisioning recipe (create a monitoring account) and, if so, the admin params the wizard must collect.

In the path:

- `name` (string, required)

---

## runbooks

The runbook library — the step lists themselves, before anyone runs them.

#### `POST /api/v1/agents/{agent_id}/runbook/run`

Run a runbook (Ansible task YAML) against a host. dry_run (default true) previews every step in check_mode. Needs manage rights on the host.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `dry_run` (true or false, optional, default `true`)
- `playbook` (string, optional)
- `variables` (object, optional, default `{}`)

#### `DELETE /api/v1/runbook-runs`

Clear play history (admin only). Without `older_than_days` deletes the whole runbook_runs history; with it, only rows older than that many days. Complements the automatic retention sweep in services/housekeeping.

Query parameters:

- `older_than_days` (whole number, optional)

#### `GET /api/v1/runbook-runs`

Block F6 — runbook execution history, newest first (optionally one host). Sibling of GET /runs (plan runs) so the unified Runs page can list plan + runbook + deploy runs together. The Event Browser adds status/effect (failed|changed|unchanged) and `q` (requested_by/runbook substring) filters. Each row carries `host` (resolved agent hostname) and `effect` so the UI renders the changed/failed/unchanged badge without a second lookup.

Query parameters:

- `agent_id` (string, optional)
- `status` (string, optional)
- `effect` (string, optional)
- `q` (string, optional)
- `limit` (whole number, optional, default `100`)

#### `GET /api/v1/runbook-runs/{run_id}`

Full detail of one play — the engine's per-step RunResult (`result`) as stored JSON, so the Event Browser can render it like a playbook job (each step ok/changed/skipped/failed) plus who ran it and when.

In the path:

- `run_id` (string, required)

#### `GET /api/v1/runbooks`

List Runbooks. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/runbooks`

Create Runbook. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `doc` (object, optional)
- `folder` (string, optional)
- `playbook` (string, optional)

#### `POST /api/v1/runbooks/from-nl`

NL → typed runbook (Agentic-OS reasoning): turn a plain-language instruction into an Ansible playbook via the chat LLM, then parse + shape-validate it (the same lint the editor uses). Returns {ok, doc, playbook} so the runbook editor can load it for the operator to review, dry-run and apply — the model authors, the human confirms. Does NOT execute anything.

The JSON body carries:

- `instruction` (string, required)
- `backend` (string, optional)

#### `POST /api/v1/runbooks/lint`

Parse + shape-validate a runbook written in Ansible task syntax. Returns {ok, kind, name, doc, playbook} (the canonical `doc` rebuilds the visual canvas; `playbook` is the doc rendered back to Ansible YAML for the text view) or {ok: false, error}.

The JSON body carries:

- `playbook` (string, optional)

#### `POST /api/v1/runbooks/role/compile`

Compile a role into an OrchestrationPlan create-payload (name/display_name/plan_type/version with steps + generated_monitoring + notifications) — POST it to /api/v1/orchestration/plans to store it.

A role is Ansible task syntax under a `role:` key, plus `monitoring.checks` / `notifications.routes`.

The JSON body carries:

- `playbook` (string, optional)

#### `DELETE /api/v1/runbooks/{runbook_id}`

Delete Runbook. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `runbook_id` (string, required)

#### `GET /api/v1/runbooks/{runbook_id}`

Get Runbook. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `runbook_id` (string, required)

#### `PUT /api/v1/runbooks/{runbook_id}`

Update Runbook. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `runbook_id` (string, required)

The JSON body carries:

- `doc` (object, optional)
- `folder` (string, optional)
- `playbook` (string, optional)

#### `GET /api/v1/scope-vars`

The variables set directly on one scope target (not the resolved inheritance — a runbook run resolves that GPO-style). Secret values are masked; `secret_keys` tells the UI which to render as password fields.

Query parameters:

- `scope_type` (string, required)
- `ou_id` (string, optional)
- `host_group_id` (string, optional)
- `agent_id` (string, optional)

#### `PUT /api/v1/scope-vars`

Set (upsert) the variables on a host/group/OU. Host scope needs manage rights on the host; group/OU scope is admin-only (broad blast radius). Keys named in `secret_keys` are encrypted at rest; a secret whose incoming value is the mask keeps its existing ciphertext (edit-without-revealing).

The JSON body carries:

- `scope_type` (string, required)
- `agent_id` (string, optional)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `secret_keys` (list of string, optional, default `[]`)
- `vars` (object, optional, default `{}`)

---

## docker

Containers and compose projects discovered on a host, and their desired state.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/agents/{agent_id}/docker-state`

One generation's full spec (the current/newest if `generation` omitted).

In the path:

- `agent_id` (string, required)

Query parameters:

- `generation` (whole number, optional)

#### `GET /api/v1/agents/{agent_id}/docker-state/converge-plan`

Preview the actions (create/remove/recreate) to make the host match a target generation vs. what is live now — the safe pre-apply diff.

In the path:

- `agent_id` (string, required)

Query parameters:

- `generation` (whole number, optional)

#### `GET /api/v1/agents/{agent_id}/docker-state/diff`

Container-level diff (added / removed / changed) between two generations.

In the path:

- `agent_id` (string, required)

Query parameters:

- `from` (whole number, required)
- `to` (whole number, required)

#### `POST /api/v1/agents/{agent_id}/docker-state/discover`

Observe the host's containers and snapshot them as a new desired-state generation (only if the canonical spec changed since the last one).

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/docker-state/generations`

Every stored container desired-state generation, newest first.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/docker-state/rollback`

Set an old generation as the new desired state (forward-only, like config).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `generation` (whole number, required)

#### `GET /api/v1/agents/{agent_id}/docker/containers`

Containers on the host (docker ps -a).

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/docker/deploy`

Deploy (idempotently replace) a container from values. dry_run shows the command without running it.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `image` (string, required)
- `name` (string, required)
- `dry_run` (true or false, optional, default `false`)
- `env` (object, optional, default `{}`)
- `ports` (list of object, optional, default `[]`)
- `restart` (string, optional, default `"unless-stopped"`)
- `volumes` (list of string, optional, default `[]`)

#### `GET /api/v1/agents/{agent_id}/docker/inspect`

Recover every container as a portable spec (docker inspect) incl. its docker-compose file — the observe side of the docker tier (desired state).

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/docker/remove`

Force-remove a container by name.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `name` (string, required)

#### `GET /api/v1/docker/app-templates`

The docker app-store catalog: containers with their README-extracted variables (env → params), ports and volumes, most-popular first.

#### `POST /api/v1/docker/app-templates/extract`

Extract one image's configurable variables from its Docker Hub README (via the OpenRouter model settings.docker_extract_model) and store it.

The JSON body carries:

- `image` (string, required)

#### `POST /api/v1/docker/app-templates/extract-batch`

Populate the docker catalog: extract variables for the top `limit` curated images (services/docker_readme.TOP_IMAGES). Per-image failures are reported, never fatal. Idempotent (an unchanged README skips the LLM).

Query parameters:

- `limit` (whole number, optional, default `100`)

---

## templates

Configuration templates — whole-file renders for configuration a codec cannot parse.

#### `GET /api/v1/template-groups`

List Template Groups. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/template-groups`

Create Template Group. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)

#### `DELETE /api/v1/template-groups/{group_id}`

Delete Template Group. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `group_id` (string, required)

#### `GET /api/v1/templates`

List Templates. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/templates`

Create Template. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)
- `nested_template_ids` (list of string, optional, default `[]`)
- `rules` (list of object, optional, default `[]`)
- `template_group_id` (string, optional)

#### `DELETE /api/v1/templates/{template_id}`

Delete Template. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `template_id` (string, required)

#### `GET /api/v1/templates/{template_id}`

Get Template. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `template_id` (string, required)

#### `PUT /api/v1/templates/{template_id}`

Update Template. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `template_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)
- `nested_template_ids` (list of string, optional, default `[]`)
- `rules` (list of object, optional, default `[]`)
- `template_group_id` (string, optional)

#### `GET /api/v1/templates/{template_id}/links`

List Template Links. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `template_id` (string, required)

#### `POST /api/v1/templates/{template_id}/links`

Create Template Link. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `template_id` (string, required)

The JSON body carries:

- `host_group` (string, required)

#### `DELETE /api/v1/templates/{template_id}/links/{link_id}`

Delete Template Link. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `template_id` (string, required)
- `link_id` (string, required)

---

## users

Accounts in this server, and their roles.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/access-grants`

List Grants. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/access-grants`

Create Grant. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `scope` (string, required)
- `subject_kind` (string, required)
- `subject_ref` (string, required)
- `agent_id` (string, optional)
- `host_group_id` (string, optional)

#### `DELETE /api/v1/access-grants/{grant_id}`

Delete Grant. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `grant_id` (string, required)

#### `GET /api/v1/api-tokens`

List Tokens. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/api-tokens`

Create Token. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)

#### `DELETE /api/v1/api-tokens/{token_id}`

Revoke Token. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `token_id` (string, required)

#### `GET /api/v1/me`

Whoami. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `GET /api/v1/users`

List Users. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/users`

Create User. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `password` (string, required)
- `username` (string, required)
- `role` (string, optional, default `"operator"`)

#### `DELETE /api/v1/users/{username}`

Delete User. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `username` (string, required)

#### `PATCH /api/v1/users/{username}`

Update User. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `username` (string, required)

The JSON body carries:

- `password` (string, optional)
- `role` (string, optional)

---

## dashboard

The overview numbers, and the dashlets a user has arranged.

#### `GET /api/v1/dashboard-widgets`

List Dashboard Widgets. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `dashboard_id` (string, optional)

#### `POST /api/v1/dashboard-widgets`

Create Dashboard Widget. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `title` (string, required)
- `widget_type` (string, required)
- `config` (object, optional, default `{}`)
- `dashboard_id` (string, optional)
- `gs_h` (whole number, optional)
- `gs_w` (whole number, optional)
- `gs_x` (whole number, optional, default `0`)
- `gs_y` (whole number, optional, default `0`)

#### `DELETE /api/v1/dashboard-widgets/{widget_id}`

Delete Dashboard Widget. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `widget_id` (string, required)

#### `PATCH /api/v1/dashboard-widgets/{widget_id}`

Update Dashboard Widget. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `widget_id` (string, required)

The JSON body carries:

- `config` (object, optional)
- `gs_h` (whole number, optional)
- `gs_w` (whole number, optional)
- `gs_x` (whole number, optional)
- `gs_y` (whole number, optional)
- `hidden` (true or false, optional)
- `pinned` (true or false, optional)
- `title` (string, optional)

#### `GET /api/v1/dashboard-widgets/{widget_id}/data`

Get Dashboard Widget Data. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `widget_id` (string, required)

#### `GET /api/v1/dashboards`

List Dashboards Route. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/dashboards`

Create Dashboard Route. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `prompt` (string, optional, default `""`)
- `source` (string, optional, default `"manual"`)

#### `DELETE /api/v1/dashboards/{dashboard_id}`

Delete Dashboard Route. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `dashboard_id` (string, required)

#### `PATCH /api/v1/dashboards/{dashboard_id}`

Update Dashboard Route. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `dashboard_id` (string, required)

The JSON body carries:

- `context` (object, optional)
- `is_default` (true or false, optional)
- `name` (string, optional)

#### `GET /api/v1/dashboards/{dashboard_id}/widgets`

List Widgets Of Dashboard. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `dashboard_id` (string, required)

---

## search

Fleet-wide search — the saved searches and the query language behind the Fleet Overview.

#### `GET /api/v1/fleet/search`

Fleet-wide search across every host's compiled desired_state — config keys/values, variables, tags, facts, applied checks/roles/thresholds — in one call. Backs the fleet-search view and the MCP fleet_search tool.

Query parameters:

- `q` (string, optional, default `""`) — substring, or key=value (path contains key AND value contains value)
- `per_host` (whole number, optional, default `50`)

#### `GET /api/v1/saved-searches`

The tenant's named Fleet-search queries, alphabetical — the recall list.

#### `POST /api/v1/saved-searches`

Save (or overwrite by name) a Fleet-search query for later recall.

The JSON body carries:

- `name` (string, required)
- `query` (string, required)

#### `DELETE /api/v1/saved-searches/{search_id}`

Delete Saved Search. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `search_id` (string, required)

#### `GET /api/v1/search`

Unified Search. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `q` (string, optional, default `""`) — Fleet search query (see services/search.py grammar)
- `limit` (whole number, optional, default `8`) — Max preview rows per type

#### `GET /api/v1/search/host-groups`

Search Host Groups. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `q` (string, optional, default `""`)
- `limit` (whole number, optional, default `50`)

#### `GET /api/v1/search/hosts`

Search Hosts. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `q` (string, optional, default `""`)
- `limit` (whole number, optional, default `50`)
- `offset` (whole number, optional, default `0`)

#### `GET /api/v1/search/services`

Search Services. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `q` (string, optional, default `""`)
- `limit` (whole number, optional, default `50`)
- `offset` (whole number, optional, default `0`)

#### `GET /api/v1/sites`

Distinct site values across the fleet, for site: autocomplete.

#### `GET /api/v1/tags`

Distinct tag keys → values across the fleet, for tag: autocomplete.

---

## helm

Kubernetes releases, as declared state.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/agents/{agent_id}/helm/charts`

Available charts to deploy (helm search repo) — the k8s app catalog.

In the path:

- `agent_id` (string, required)

Query parameters:

- `query` (string, optional, default `""`)

#### `POST /api/v1/agents/{agent_id}/helm/install`

helm upgrade --install — deploy/upgrade a release on the cluster.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `chart` (string, required)
- `name` (string, required)
- `create_namespace` (true or false, optional, default `true`)
- `namespace` (string, optional, default `"default"`)
- `values` (object, optional)
- `values_yaml` (string, optional, default `""`)
- `wait` (true or false, optional, default `false`)

#### `GET /api/v1/agents/{agent_id}/helm/releases`

Deployed k8s releases (helm list -A) — what's running on the cluster.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/helm/render`

helm template — render manifests without a cluster (preview).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `chart` (string, required)
- `name` (string, required)
- `namespace` (string, optional, default `"default"`)
- `values` (object, optional)
- `values_yaml` (string, optional, default `""`)

#### `GET /api/v1/agents/{agent_id}/helm/repos`

Helm Repos. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/helm/repos`

Helm Add Repo. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `url` (string, required)

#### `POST /api/v1/agents/{agent_id}/helm/rollback`

Helm Rollback. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `namespace` (string, optional, default `"default"`)
- `revision` (whole number, optional)

#### `POST /api/v1/agents/{agent_id}/helm/uninstall`

Helm Uninstall. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `namespace` (string, optional, default `"default"`)

#### `GET /api/v1/agents/{agent_id}/helm/values`

A chart's default values (helm show values) — drives the configure form.

In the path:

- `agent_id` (string, required)

Query parameters:

- `chart` (string, required)

---

## systems

Test systems: a clone of a production system, for rehearsing a change.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/systems`

List Systems. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/systems`

Persist a System (typically a confirmed+named proposal). Each member's non-core fields (image/chart/compose_file/…) are stored in its config blob.

The JSON body carries:

- `name` (string, required)
- `description` (string, optional)
- `edges` (list of object, optional, default `[]`)
- `members` (list of object, optional, default `[]`)
- `seed_agent_id` (string, optional)

#### `GET /api/v1/systems/propose`

Propose (not persist) a System from a seed host: its apps across docker / k8s / native + compose-derived wiring. The read-only foundation for clone-a-prod-system.

Query parameters:

- `agent_id` (string, required)
- `name` (string, optional)

#### `DELETE /api/v1/systems/{system_id}`

Delete System. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `system_id` (string, required)

#### `GET /api/v1/systems/{system_id}`

Get System. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `system_id` (string, required)

#### `POST /api/v1/systems/{system_id}/clone`

Clone the System's seed host into a sandbox on the target (cross-tier: docker names prefixed, host ports dropped). Dry-run by default — preview the config plan + docker run commands before any write. The base of the rehearsal plane.

In the path:

- `system_id` (string, required)

The JSON body carries:

- `target_agent_id` (string, required)
- `dry_run` (true or false, optional, default `true`)

#### `POST /api/v1/systems/{system_id}/promote`

Promote a rehearsed change to prod as one atomic change-set (rolls the whole set back if any member fails). Gated on a green rehearsal unless disabled.

In the path:

- `system_id` (string, required)

The JSON body carries:

- `target_agent_id` (string, required)
- `dry_run` (true or false, optional, default `false`)
- `image_overrides` (object, optional, default `{}`)
- `rehearse_first` (true or false, optional, default `true`)

#### `POST /api/v1/systems/{system_id}/rehearse`

Rehearse the System in a sandbox on the target: bring its docker members up for real (optionally with image overrides = the change under test), health-gate them, then tear down. Returns pass/fail — the behavioral test before prod.

In the path:

- `system_id` (string, required)

The JSON body carries:

- `target_agent_id` (string, required)
- `image_overrides` (object, optional, default `{}`)
- `teardown` (true or false, optional, default `true`)

---

## compliance

Software compliance: which hosts hold a version they should not.

#### `GET /api/v1/compliance-rules`

List Rules. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/compliance-rules`

Create Rule. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `scope_type` (string, required)
- `agent_id` (string, optional)
- `enabled` (true or false, optional, default `true`)
- `forbidden` (list of string, optional, default `[]`)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `required` (list of string, optional, default `[]`)
- `severity` (string, optional, default `"CRIT"`)

#### `DELETE /api/v1/compliance-rules/{rule_id}`

Delete Rule. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rule_id` (string, required)

#### `PUT /api/v1/compliance-rules/{rule_id}`

Update Rule. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rule_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `scope_type` (string, required)
- `agent_id` (string, optional)
- `enabled` (true or false, optional, default `true`)
- `forbidden` (list of string, optional, default `[]`)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `required` (list of string, optional, default `[]`)
- `severity` (string, optional, default `"CRIT"`)

#### `POST /api/v1/compliance-rules/{rule_id}/evaluate`

Evaluate Now. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rule_id` (string, required)

#### `GET /api/v1/compliance-rules/{rule_id}/results`

Rule Results. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rule_id` (string, required)

---

## graphs

Metric series for plotting: what exists, and the points in a time range.

#### `GET /api/v1/graphs`

List Graphs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/graphs`

Create Graph. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `graph_type` (string, optional, default `"normal"`)
- `items` (list of object, optional, default `[]`)
- `show_legend` (true or false, optional, default `true`)
- `show_working_time` (true or false, optional, default `false`)
- `y_axis_mode` (string, optional, default `"calculated"`)

#### `DELETE /api/v1/graphs/{graph_id}`

Delete Graph. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `graph_id` (string, required)

#### `GET /api/v1/graphs/{graph_id}`

Get Graph. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `graph_id` (string, required)

#### `PUT /api/v1/graphs/{graph_id}`

Update Graph. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `graph_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `graph_type` (string, optional, default `"normal"`)
- `items` (list of object, optional, default `[]`)
- `show_legend` (true or false, optional, default `true`)
- `show_working_time` (true or false, optional, default `false`)
- `y_axis_mode` (string, optional, default `"calculated"`)

#### `GET /api/v1/graphs/{graph_id}/data`

Combined series data for every item in the graph, one call — each item's tier (raw/hourly/daily) is picked independently by metrics_query.query_series based on `since`'s age, same as a plain per-agent metric series. `function` selects which of the tier's value/min_value/max_value to plot; "last" (Zabbix's pie-only function) behaves like "avg" here since graphs are line-based, not pie.

In the path:

- `graph_id` (string, required)

Query parameters:

- `since` (string, optional) — Only points at or after this time

---

## host-groups

Named sets of hosts, used wherever a policy or a rollout needs a target.

#### `GET /api/v1/host-groups`

List Host Groups. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/host-groups`

Create Host Group. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)

#### `DELETE /api/v1/host-groups/{group_id}`

Delete Host Group. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `group_id` (string, required)

#### `PUT /api/v1/host-groups/{group_id}`

Update Host Group. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `group_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)

#### `PUT /api/v1/host-groups/{group_id}/members`

Replace Host Group Members. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `group_id` (string, required)

The JSON body carries:

- `agent_ids` (list of string, required)

#### `GET /api/v1/host-groups/{group_id}/policy-report`

Block O3 — which orchestration policies apply to this group's members. Iterates the members, compiles each one's (read-only) desired state via the same GPO resolver the host view uses, and unions the applied plans with a per-plan count of how many members they land on. Read-only; never persists a generation (uses the compiler's pure build half).

In the path:

- `group_id` (string, required)

---

## notifications

Channels and escalation: who is told, how, and after how long.

#### `GET /api/v1/notification-rules`

List Notification Rules. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/notification-rules`

Create Notification Rule. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `channel` (string, required)
- `name` (string, required)
- `target` (string, required)
- `conditions` (object, optional)
- `enabled` (true or false, optional, default `true`)
- `enforced` (true or false, optional, default `false`)
- `escalate_after_minutes` (whole number, optional)
- `host_filter` (string, optional)
- `link_order` (whole number, optional, default `100`)
- `min_state` (string, optional, default `"WARN"`)
- `on_problem` (true or false, optional, default `true`)
- `on_recovery` (true or false, optional, default `true`)
- `ou_id` (string, optional)
- `scope_plan_id` (string, optional)
- `scope_service_name` (string, optional)
- `scope_type` (string, optional, default `"global"`)
- `scope_value` (string, optional)
- `service_filter` (string, optional)
- `tag_filter` (object, optional)
- `time_period_id` (string, optional)

#### `DELETE /api/v1/notification-rules/{rule_id}`

Delete Notification Rule. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rule_id` (string, required)

#### `PATCH /api/v1/notification-rules/{rule_id}`

Patch Notification Rule. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rule_id` (string, required)

The JSON body carries:

- `enabled` (true or false, optional)
- `enforced` (true or false, optional)
- `link_order` (whole number, optional)
- `ou_id` (string, optional)

#### `PUT /api/v1/notification-rules/{rule_id}`

Update Notification Rule. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rule_id` (string, required)

The JSON body carries:

- `channel` (string, required)
- `name` (string, required)
- `target` (string, required)
- `conditions` (object, optional)
- `enabled` (true or false, optional, default `true`)
- `enforced` (true or false, optional, default `false`)
- `escalate_after_minutes` (whole number, optional)
- `host_filter` (string, optional)
- `link_order` (whole number, optional, default `100`)
- `min_state` (string, optional, default `"WARN"`)
- `on_problem` (true or false, optional, default `true`)
- `on_recovery` (true or false, optional, default `true`)
- `ou_id` (string, optional)
- `scope_plan_id` (string, optional)
- `scope_service_name` (string, optional)
- `scope_type` (string, optional, default `"global"`)
- `scope_value` (string, optional)
- `service_filter` (string, optional)
- `tag_filter` (object, optional)
- `time_period_id` (string, optional)

#### `GET /api/v1/notifications`

List Notifications. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `limit` (whole number, optional, default `100`)

---

## rollouts

Staged change across many hosts, with the gate between stages.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/rollouts`

List Rollouts. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/rollouts`

Create Rollout. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `runbook_name` (string, required)
- `scope_type` (string, required)
- `agent_id` (string, optional)
- `by_ou` (true or false, optional, default `false`)
- `canary` (true or false, optional, default `true`)
- `dry_run` (true or false, optional, default `false`)
- `host_group_id` (string, optional)
- `max_fail_pct` (number, optional, default `0.0`)
- `one_at_a_time` (true or false, optional, default `false`)
- `ou_id` (string, optional)
- `strategy` (list of string, optional, default `[1, "25%", "rest"]`)
- `test_runbook_name` (string, optional)
- `variables` (object, optional, default `{}`)
- `wait_seconds` (whole number, optional, default `30`)

#### `DELETE /api/v1/rollouts/{rollout_id}`

Delete Rollout. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rollout_id` (string, required)

#### `GET /api/v1/rollouts/{rollout_id}`

Get Rollout. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rollout_id` (string, required)

#### `POST /api/v1/rollouts/{rollout_id}/abort`

Abort Rollout. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rollout_id` (string, required)

#### `POST /api/v1/rollouts/{rollout_id}/start`

Start Rollout. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `rollout_id` (string, required)

---

## sites

Subnet-scoped policy: a site is a set of CIDRs, and a host belongs to one by its primary address.

#### `GET /api/v1/policy-sites`

List Sites. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/policy-sites`

Create Site. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)
- `ou_id` (string, optional)
- `subnets` (list of string, optional, default `[]`)

#### `DELETE /api/v1/policy-sites/{site_id}`

Delete Site. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `site_id` (string, required)

#### `PATCH /api/v1/policy-sites/{site_id}`

Patch Site. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `site_id` (string, required)

The JSON body carries:

- `ou_id` (string, optional)

#### `PUT /api/v1/policy-sites/{site_id}`

Update Site. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `site_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `description` (string, optional, default `""`)
- `ou_id` (string, optional)
- `subnets` (list of string, optional, default `[]`)

#### `PUT /api/v1/policy-sites/{site_id}/subnets`

Replace Site Subnets. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `site_id` (string, required)

The JSON body carries:

- `cidrs` (list of string, required)

---

## business-services

Aggregation: many technical states rolled into one service that a non-operator understands.

#### `GET /api/v1/business-services`

List Bs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/business-services`

Create Bs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `description` (string, optional)
- `enabled` (true or false, optional, default `true`)
- `logic` (string, optional, default `"all"`)
- `members` (list of object, optional, default `[]`)

#### `DELETE /api/v1/business-services/{bs_id}`

Delete Bs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `bs_id` (string, required)

#### `PUT /api/v1/business-services/{bs_id}`

Update Bs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `bs_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `description` (string, optional)
- `enabled` (true or false, optional, default `true`)
- `logic` (string, optional, default `"all"`)
- `members` (list of object, optional, default `[]`)

#### `POST /api/v1/business-services/{bs_id}/evaluate`

Evaluate Bs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `bs_id` (string, required)

---

## document

The server-as-document view: one host as one JSON document, and its history.

#### `POST /api/v1/agents/{agent_id}/blast-radius`

What-if guardrail: predict the effect of applying `resources` — the change diff (state/plan) + the inbound dependents that could be affected — WITHOUT writing. Call before apply.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `resources` (list of object, optional, default `[]`)

#### `GET /api/v1/agents/{agent_id}/document`

The complete server-document for one host — the AI's full-context read.

In the path:

- `agent_id` (string, required)

Query parameters:

- `include` (string, optional, default `"config,desired,generations,topology"`) — Comma-separated sections: config,desired,generations,topology.

#### `POST /api/v1/agents/{agent_id}/explain`

Self-documenting infra: the LLM documents this server (no question) or answers a question, grounded strictly in its live state document. The answer cannot go stale — it's generated from the live desired+observed state each time.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `question` (string, optional)

#### `GET /api/v1/agents/{agent_id}/export`

Reproducibility: capture this running server as a PORTABLE spec (its structured config as re-appliable resources) — for clone / golden / DR.

In the path:

- `agent_id` (string, required)

#### `POST /api/v1/agents/{agent_id}/materialize`

Re-materialize a portable spec onto THIS host (the target). Dry-run by default — preview the plan before writing (clone/DR safety).

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `spec` (object, required)
- `dry_run` (true or false, optional, default `true`)

---

## scheduler

Recurring work: what runs when, and whether the last run succeeded.

#### `GET /api/v1/scheduled-jobs`

List Jobs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/scheduled-jobs`

Create Job. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `cron` (string, required)
- `name` (string, required)
- `runbook_name` (string, required)
- `scope_type` (string, required)
- `agent_id` (string, optional)
- `dry_run` (true or false, optional, default `false`)
- `enabled` (true or false, optional, default `true`)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `variables` (object, optional, default `{}`)

#### `DELETE /api/v1/scheduled-jobs/{job_id}`

Delete Job. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `job_id` (string, required)

#### `PUT /api/v1/scheduled-jobs/{job_id}`

Update Job. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `job_id` (string, required)

The JSON body carries:

- `cron` (string, required)
- `name` (string, required)
- `runbook_name` (string, required)
- `scope_type` (string, required)
- `agent_id` (string, optional)
- `dry_run` (true or false, optional, default `false`)
- `enabled` (true or false, optional, default `true`)
- `host_group_id` (string, optional)
- `ou_id` (string, optional)
- `variables` (object, optional, default `{}`)

#### `POST /api/v1/scheduled-jobs/{job_id}/run-now`

Fire a scheduled job immediately (ignoring its cron), against its scope.

In the path:

- `job_id` (string, required)

---

## security

CVE exposure per host, and the actions taken about it.

#### `POST /api/v1/security/bulk-update`

Apply (security) package updates to many hosts at once — the "bulk update" over the CVE view's affected hosts. Each host is authorized individually (user_can_manage_agent, like the per-host route) and applied best-effort: a per-host failure lands in `results` with its error, it does not abort the batch. dry_run is honored (check_mode preview).

The JSON body carries:

- `agent_ids` (list of string, required)
- `dry_run` (true or false, optional, default `true`)
- `security_only` (true or false, optional, default `true`)

#### `GET /api/v1/security/cves`

Fleet-wide CVEs from correlated pending upgrades, aggregated per CVE with the affected hosts. Filterable by severity / distro / host / text / fix.

Query parameters:

- `severity` (string, optional)
- `distro` (string, optional)
- `agent_id` (string, optional)
- `fix_available` (true or false, optional)
- `q` (string, optional)

#### `GET /api/v1/security/feed-status`

Last CVE-feed refresh outcome + per-distro advisory counts.

#### `POST /api/v1/security/refresh`

Force an immediate CVE-feed refresh + a fleet-wide correlation sweep (admin only) so the Security page repopulates right away.

#### `GET /api/v1/security/summary`

Counts by severity + distro + affected hosts for the Security dashboard.

---

## system-settings

This server's own settings.

#### `PUT /api/v1/system/helm-proxy`

Set the Bossman-wide helm chart-pull proxy (edited in Admin Settings). Writes the DB row AND refreshes the in-process cache so the next helm command uses it immediately, without a restart — see services/helm_app.set_helm_proxy.

The JSON body carries:

- `http_proxy` (string, optional, default `""`)
- `no_proxy` (string, optional, default `""`)

#### `PUT /api/v1/system/netboot`

Enter/rotate the PXE netboot secret and turn netboot on/off. Enabling without any secret set (neither here nor the BOSSMAN_NETBOOT_SECRET env fallback) is rejected — an open install endpoint must never be a one-click mistake.

The JSON body carries:

- `enabled` (true or false, required)
- `secret` (string, optional)

#### `PUT /api/v1/system/retention`

Set the event/run history retention window (Admin settings). Housekeeping's hourly sweep prunes runbook_runs + audit_log rows older than this many days; 0 disables auto-purge (keep forever). The Event Browser also offers a manual purge that ignores this window.

The JSON body carries:

- `run_retention_days` (whole number, required)

#### `GET /api/v1/system/yolo-mode`

Get Yolo Mode. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `PUT /api/v1/system/yolo-mode`

Set Yolo Mode. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `enabled` (true or false, required)

---

## time-periods

Named windows — business hours, maintenance — that other rules refer to.

#### `GET /api/v1/time-periods`

List Time Periods. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/time-periods`

Create Time Period. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `alias` (string, optional, default `""`)
- `exceptions` (object, optional, default `{}`)
- `excludes` (list of string, optional, default `[]`)
- `ranges` (object, optional, default `{}`)

#### `DELETE /api/v1/time-periods/{period_id}`

Delete Time Period. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `period_id` (string, required)

#### `PUT /api/v1/time-periods/{period_id}`

Update Time Period. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `period_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `alias` (string, optional, default `""`)
- `exceptions` (object, optional, default `{}`)
- `excludes` (list of string, optional, default `[]`)
- `ranges` (object, optional, default `{}`)

#### `GET /api/v1/time-periods/{period_id}/usage`

What would be affected by changing this window — asked before editing, not after.

In the path:

- `period_id` (string, required)

---

## change-proposals

Changes waiting for a human decision, with the reasoning that produced them.

#### `GET /api/v1/change-proposals`

AI-proposed changes, newest first. `status=pending` for the approval queue.

Query parameters:

- `status` (string, optional)
- `limit` (whole number, optional, default `100`)

#### `GET /api/v1/change-proposals/{proposal_id}`

One proposal with its full dry-run preview + payload — what a human reviews before approving.

In the path:

- `proposal_id` (string, required)

#### `POST /api/v1/change-proposals/{proposal_id}/approve`

Approve → apply the change for real, recording the outcome + who approved.

In the path:

- `proposal_id` (string, required)

#### `POST /api/v1/change-proposals/{proposal_id}/reject`

Reject Proposal. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `proposal_id` (string, required)

---

## clusters

Hosts that belong together as one failure domain.

#### `GET /api/v1/clusters`

List Clusters. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/clusters`

Create Cluster. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `aggregation_mode` (string, optional, default `"worst"`)
- `node_ids` (list of string, optional, default `[]`)
- `primary_node_id` (string, optional)
- `service_patterns` (list of string, optional, default `[]`)

#### `DELETE /api/v1/clusters/{cluster_id}`

Removes the cluster host and its aggregated services. The NODES are untouched — they are real hosts that existed before the cluster and keep their own services.

In the path:

- `cluster_id` (string, required)

#### `PUT /api/v1/clusters/{cluster_id}`

Update Cluster. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `cluster_id` (string, required)

The JSON body carries:

- `name` (string, required)
- `aggregation_mode` (string, optional, default `"worst"`)
- `node_ids` (list of string, optional, default `[]`)
- `primary_node_id` (string, optional)
- `service_patterns` (list of string, optional, default `[]`)

---

## value-maps

Turning a raw number into the word a human reads.

#### `GET /api/v1/value-maps`

List Value Maps. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/value-maps`

Create Value Map. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `mappings` (object, required)
- `name` (string, required)

#### `DELETE /api/v1/value-maps/{value_map_id}`

Delete Value Map. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `value_map_id` (string, required)

#### `PUT /api/v1/value-maps/{value_map_id}`

Update Value Map. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `value_map_id` (string, required)

The JSON body carries:

- `mappings` (object, required)
- `name` (string, required)

---

## vm

Virtual machine lifecycle on a hypervisor.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/vm`

Vm List. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/vm/install`

Vm Install. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `disk` (string, required) — Template disk filename to create/attach
- `iso` (string, required) — Installer ISO filename in the lab's ISO dir
- `name` (string, required) — VM name (also the disk/console handle)
- `disk_gib` (whole number, optional, default `40`)

#### `POST /api/v1/vm/pxe-test`

Vm Pxe Test. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `disk` (string, required) — Blank target disk to receive the restore
- `mac` (string, required) — NIC MAC the DHCP/PXE flow keys on
- `name` (string, required)
- `disk_gib` (whole number, optional, default `60`)

#### `POST /api/v1/vm/{name}/stop`

Vm Stop. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `name` (string, required)

---

## admin

Server-side maintenance that is not about any one host.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `GET /api/v1/admin/diagnostics`

Get Diagnostics. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/admin/housekeeping/run`

Run Housekeeping Now. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/admin/log-level`

Set Log Level. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `level` (string, required)

---

## agent-release

Agent packages this server offers for installation and upgrade.

#### `GET /api/v1/agent-release`

The cached release view + which enrolled hosts are behind it. No network call here (the poller refreshes the cache); use POST /check to force one.

#### `POST /api/v1/agent-release/check`

Force a re-check of the GitHub release channel now, then return the fresh view (same shape as GET).

#### `POST /api/v1/agent-release/rollout`

Download the latest package (per host OS family), VERIFY its sha256 against the release manifest, and push it to each target over the mTLS self-update channel. The verified bytes are cached per kind so a fleet rollout downloads each package at most once.

The JSON body carries:

- `agent_ids` (list of string, optional, default `[]`)
- `all_outdated` (true or false, optional, default `false`)

---

## audit

Who did what, in this server.

#### `POST /api/v1/agents/{agent_id}/audit-external/scan`

Capture out-of-band (drift) changes to this host's managed config via auditd and fold them into the audit trail. Live path: install watch rules for the files in the host's desired_state, then read auditd since `since`. Or pass `raw` (pre-collected ausearch output) to parse+ingest directly. Rows land in audit_log as actor_kind=external / source=auditd, so they show up in the Audit log next to Bossman's own changes.

In the path:

- `agent_id` (string, required)

The JSON body carries:

- `raw` (string, optional)
- `since` (string, optional, default `"today"`)

#### `GET /api/v1/audit`

List Audit. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `actor` (string, optional)
- `category` (string, optional)
- `status` (string, optional)
- `q` (string, optional) — substring match on action/path/target
- `since` (string, optional)
- `limit` (whole number, optional, default `100`)

#### `GET /api/v1/audit/stats`

Audit Stats. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

---

## auth

Logging in. Everything else needs the bearer token this returns.

#### `POST /api/v1/auth/login`

Log in and get the bearer token everything else needs.

Send `{"username", "password"}`; the response carries `access_token`, which goes into `Authorization: Bearer <token>` on every other call in this API. Only this endpoint and `/healthz` work without one.

A failed attempt is recorded in the audit trail with the source IP (action `auth.login_failed`) — a login that nobody can see failing is a login nobody can see being attacked.

The JSON body carries:

- `password` (string, required)
- `username` (string, required)

#### `GET /api/v1/auth/setup`

Unauthenticated on purpose — it is asked BEFORE anyone can log in, and its only answer is a boolean about whether an account exists. It leaks nothing that a failed login would not.

#### `POST /api/v1/auth/setup`

Create the FIRST operator account, and only the first.

WHY THIS EXISTS. The native install told the operator to run `bossman-create-admin <user> <password>` on the console — a password in shell history, and a step that cannot be done at all by someone who has the web console open and no shell on that host.

WHY IT CANNOT BE ABUSED, and this is the whole design: the route refuses the moment ANY account exists. An installation that has been set up returns 409 forever, so this is not a signup endpoint that someone forgot to protect — it is a one-shot that closes behind itself. The check and the insert share one transaction, so two browsers racing the form cannot both win.

It returns a token, so the operator is logged in and does not have to type the password again — and the audit trail records who was created, from where.

The JSON body carries:

- `password` (string, required)
- `username` (string, required)

---

## capabilities

What a host can provide and what it requires — the matcher behind the lego model.

#### `GET /api/v1/agents/{agent_id}/capabilities`

Host Capabilities. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/capabilities/match`

Match. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `agent_id` (string, required) — the consumer host whose open requirements to satisfy

#### `GET /api/v1/capabilities/providers`

Providers. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `capability` (string, required)
- `backend` (string, optional, default `""`) — restrict to a backend the consumer accepts (alias-aware)

---

## config-templates

The template catalogue itself: schemas, samples and the Jinja sources.

#### `GET /api/v1/config-templates`

Every Class-B template as [{name, target_path, source}] — NO BODIES.

It used to return each template's body, schema and sample: measured against this catalog, a 36 MB JSON document assembled in memory on every call. The host page was moved off it once already (see the note on /config-templates/index, "replaces a 33.7 MB download"), but seven package snapins still called it — each to pull the whole catalog and then `.find()` ONE hard-coded name. They now ask for that name directly.

A listing is a listing: what a caller choosing a template needs is the name, the file it renders and why the claim exists. The body comes from GET /config-templates/{name}, for the one that was chosen.

NO withheld COUNT HERE, deliberately. Bossman serves the whole tree, so there is nothing withheld to report; the agent's reply carries that number because the PACKAGE ships only the reachable subset. Adding a permanent "withheld: 0" to this reply would be a second place claiming to answer a question only the agent has.

#### `GET /api/v1/config-templates/index`

{paths: {"/etc/nginx/nginx.conf": {template, source, role?}}, conflicts: [...]}.

The explicit answer to "which template renders THIS file", replacing a basename guess that resolved /etc/aardvark-dns/aardvark-dns.conf to the template rendering forward.conf — and, since the write path is template_render (whole file, no merge), would have written one file's content over another.

DECLARED BEFORE /{name} on purpose. FastAPI matches routes in declaration order, so the path parameter below would otherwise swallow "index" and serve a 404 for a template literally named index. Route order is load-bearing here, not style.

Also replaces a 33.7 MB download: the host page used to fetch every template BODY across 5460 directories to do a string comparison. This is path→name pairs.

Query parameters:

- `family` (string, optional, default `""`)
- `agent_id` (string, optional)

#### `GET /api/v1/config-templates/{name}`

Get Config Template. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `name` (string, required)

---

## deployments

A rollout in progress, per host.

#### `GET /api/v1/deployments`

The multi-host deployment audit trail, newest first.

The two optional filters are the navigable EDGES the UI needs (docs/ui-workspaces.md): they answer "what is deployed on THIS host" and "where is THIS artefact deployed" — the links that were missing between the Library and the Fleet. Without them the operator can only read the flat audit trail.

- `agent_id` → deployments whose per-host results include that host. `results` is JSONB `[{agent_id, …}]`, so this is a containment match (`@>`), which the GIN-indexable operator, not a Python-side scan of every row. - `target_ref` → deployments of one artefact (the plan/runbook name).

Query parameters:

- `limit` (whole number, optional, default `50`)
- `agent_id` (string, optional)
- `target_ref` (string, optional)

#### `POST /api/v1/deployments/run`

Resolve the target set, run the plan/runbook against each host, and persist one DeploymentRun grouping the per-host child runs.

The JSON body carries:

- `kind` (string, required)
- `dry_run` (true or false, optional, default `true`)
- `name` (string, optional)
- `params` (object, optional, default `{}`)
- `prefix` (string, optional)
- `runbook_name` (string, optional)
- `runbook_playbook` (string, optional)
- `targets` (object, optional) — DeploymentTargets

#### `GET /api/v1/deployments/{deployment_id}`

Get Deployment. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `deployment_id` (string, required)

---

## devices

Things that are not hosts: switches, PDUs, anything polled off-host.

#### `GET /api/v1/devices`

List Devices. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `POST /api/v1/devices`

Create Device. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `target` (string, required)
- `auth_pass` (string, optional, default `""`)
- `auth_proto` (string, optional, default `"SHA"`)
- `check_names` (list of string, optional, default `[]`)
- `community` (string, optional, default `"public"`)
- `context` (string, optional, default `""`)
- `kind` (string, optional, default `"snmp"`)
- `password` (string, optional, default `""`)
- `priv_pass` (string, optional, default `""`)
- `priv_proto` (string, optional, default `"AES"`)
- `sec_level` (string, optional, default `"authPriv"`)
- `sec_name` (string, optional, default `""`)
- `snmp_version` (string, optional, default `"v2c"`)
- `user` (string, optional, default `""`)

#### `DELETE /api/v1/devices/{device_id}`

Delete Device. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `device_id` (string, required)

---

## enroll

How a host joins the fleet — the token it presents and the certificate it gets back.

#### `POST /api/v1/enroll`

Handle Enroll. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `name` (string, required)
- `token` (string, required)
- `address` (string, optional)
- `enroll_secret` (string, optional)

#### `POST /api/v1/enroll/deploy`

Handle Deploy. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `host` (string, required)
- `port` (whole number, optional)
- `write` (true or false, optional)

#### `GET /api/v1/enroll/info`

Enroll Info. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

---

## events

The event console: raw events before they are anything else.

#### `GET /api/v1/events`

List Events. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `kind` (string, optional)
- `host` (string, optional)
- `max_severity` (whole number, optional) — Only events at or below this syslog severity (0=emerg..7=debug)
- `unacked` (true or false, optional, default `false`)
- `limit` (whole number, optional, default `200`)

#### `GET /api/v1/events/stats`

Counts for the console header: total, unacked, and unacked at severity <= warning (the ones that actually matter).

#### `POST /api/v1/events/{event_id}/ack`

Ack Event. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `event_id` (string, required)

---

## knowledge

The retrieval memory the chat and the remediation reasoning read from.

#### `POST /api/v1/ask`

Retrieve-then-generate over the live infrastructure knowledge index.

The JSON body carries:

- `question` (string, required)
- `host_id` (string, optional)
- `top_k` (whole number, optional, default `8`)

#### `POST /api/v1/knowledge/reindex`

Rebuild the infra knowledge index now (incremental — only changed cards are re-embedded).

#### `GET /api/v1/knowledge/stats`

What the AI currently knows: card counts by kind, the embedding model, and how fresh the index is.

---

## processes

What is running on a host, and its resource use.

#### `GET /api/v1/agents/{agent_id}/ebpf`

On-demand eBPF detail behind the host's latency heatmaps — the 'what': the top outbound connection targets (comm → dst:port, connects) and the slowest recent block-I/O requests (comm, device, latency, op). Live pass-through to the agent, never stored.

In the path:

- `agent_id` (string, required)

Query parameters:

- `limit` (whole number, optional, default `20`)

#### `GET /api/v1/agents/{agent_id}/processes`

Get Agent Processes. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)

Query parameters:

- `limit` (whole number, optional, default `0`) — Keep only the top-N hungriest processes (0 = all)

#### `GET /api/v1/agents/{agent_id}/processes/history`

CPU% + RSS history for one process, keyed by command name (comm) — the combined-graph source behind an expanded Processes-tab row. History is tracked per comm, not per pid, so it stays continuous across a service restart (a restart changes the pid but not the comm) and doesn't accumulate dead-pid series. Reads the agent's `process_cpu_percent` / `process_rss_bytes` series (aggregated per comm) straight from stored metrics. Raw tier only — the 14-day raw retention ages out old data.

In the path:

- `agent_id` (string, required)

Query parameters:

- `comm` (string, required) — Command name (comm) to fetch CPU/RSS history for
- `since` (string, optional) — Only points at or after this time

---

## apps

Application definitions layered over hosts.

#### `GET /api/v1/apps`

The unified app catalog: [{id, label, category, icon, description, configurable, targets:{native:{…}}}]. A thin view over package-catalog.

#### `GET /api/v1/apps/{app_id}`

One App with its values_schema + sample (for the configure form), read from the app's Class-B template dir when present.

In the path:

- `app_id` (string, required)

---

## chunks

The indexed pieces of that memory.

#### `POST /api/v1/chunks/index`

Index Chunk Route. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `chunk_id` (string, required)
- `chunk_name` (string, required)
- `plan_name` (string, required)
- `source_text` (string, required)
- `source_hash` (string, optional)
- `translated_json` (string, optional)

#### `POST /api/v1/chunks/similar`

Similar Chunks Route. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `source_text` (string, required)
- `threshold` (number, optional)
- `top_k` (whole number, optional, default `3`)

---

## config-fields

One question, one answer: which fields does this configuration file have, and how is it written?

#### `GET /api/v1/config-fields`

One field spec for `path`: {path, write, format?, separator?, template?, fields:{key:FieldDef}, available}.

Query parameters:

- `path` (string, required)
- `family` (string, optional, default `""`)
- `agent_id` (string, optional)

#### `GET /api/v1/config-generated`

{path: {line, quote, marker}} — every config file whose own header says it is machine-written.

A MAP rather than a per-path question, because the callers render whole lists of files: the host Configuration tab shows every discovered config file at once, and asking /config-fields 40 times to annotate them would trade one small read for forty. 84 files across the measured corpus, a few kB.

The quote is passed through verbatim and no verdict is attached. "DO NOT EDIT THIS FILE" and "Please don't edit this EXAMPLE config file. Create and edit /etc/munin/munin-conf.d/…" call for very different actions, and the file is the one that knows which — see scripts/find_generated_files.py for how the sentence is proven to be about the file itself rather than about its reports, its keys or one block.

---

## config-sync

Bringing a host's configuration back in line with what is declared for it.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `POST /api/v1/config-sync/run`

Run Now. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `GET /api/v1/config-sync/status`

Status. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

---

## forecast

Where a series is heading, for capacity questions.

#### `GET /api/v1/agents/{agent_id}/forecast`

Agent Forecast. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)

Query parameters:

- `metric` (string, optional, default `"disk_used_pct"`)
- `threshold` (number, optional, default `90.0`)
- `lookback_days` (whole number, optional, default `30`)

#### `GET /api/v1/forecast/capacity`

Capacity. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `metric` (string, optional, default `"disk_used_pct"`)
- `threshold` (number, optional, default `90.0`)
- `lookback_days` (whole number, optional, default `30`)
- `warn_days` (whole number, optional, default `30`)
- `crit_days` (whole number, optional, default `7`)

---

## help

The in-product help texts.

#### `GET /api/v1/help`

The README markdown, rendered by the UI's Help page.

#### `GET /api/v1/help/search`

Doc sections matching a query — backs the AI's search_help tool and a Help-page search box.

Query parameters:

- `q` (string, required)
- `limit` (whole number, optional, default `5`)

---

## mmc

The management console: the snap-in tree, and one snap-in's rows and actions for one host.

#### `GET /api/v1/agents/{agent_id}/mmc`

The console tree for one host: every snap-in, its nodes, and whether each can serve this host.

The tool list is fetched ONCE here rather than per node, and its failure is carried rather than raised: a host that is down still has a console tree — every snap-in reads `unknown`, which is the honest answer and the one that lets the reader tell "cannot" from "cannot tell".

In the path:

- `agent_id` (string, required)

#### `GET /api/v1/agents/{agent_id}/mmc/{snapin_id}/{node_id}`

One node's result pane: its columns (from the catalog) and its rows (from the host).

An `endpoint` source is called IN-PROCESS through the app's own router, not over HTTP to ourselves: the caller's credentials are already established, and a self-request would need a second set of them plus a round trip. A `tool` source goes through the agent client with the catalog's fixed parameters — the catalog never receives parameters from the request, so a node cannot be turned into an arbitrary module call by whoever crafts the URL.

In the path:

- `agent_id` (string, required)
- `snapin_id` (string, required)
- `node_id` (string, required)

---

## modules

The Ansible-compatible module catalogue: specifications, and which are translated.

#### `GET /api/v1/modules`

The whole catalog in one call: per-collection progress + one row per module (translated rows carry description/writes).

#### `GET /api/v1/modules/{fqcn}`

One module's detail: the stored metadata + Starlark source for a translated module, or the dumped argspec/description for one still in the queue (so the UI can show every module, not just finished ones).

In the path:

- `fqcn` (string, required)

---

## runs

One execution of something, whatever started it.

#### `GET /api/v1/runs`

List Runs. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `agent_id` (string, optional)
- `plan_name` (string, optional)
- `status` (string, optional)
- `limit` (whole number, optional, default `50`)

#### `GET /api/v1/runs/{run_id}`

Get Run. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `run_id` (string, required)

---

## severity-labels

The names this installation gives to severities.

#### `GET /api/v1/severity-labels`

List Severity Labels. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

#### `PUT /api/v1/severity-labels/{state}`

Update Severity Label. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `state` (string, required)

The JSON body carries:

- `color` (string, required)
- `label` (string, required)

---

## vault

Secrets by reference: a runbook names a secret, never carries it.

**These endpoints change a host or this server.** Where a module or a resource is
involved, `dry_run: true` returns the plan instead of applying it — use it first.

#### `POST /api/v1/vault/encrypt`

Turn a plaintext into a `vault:v1:` handle (optionally generating a strong passphrase first), and return ONLY the handle.

This exists so a UI never has to put a plaintext secret into an operation: it posts the passphrase once, keeps the handle, and the handle is what travels in the plan (see disk_ops' LUKS ops, where apply() is the only place that decrypts). The plaintext is not persisted anywhere by this endpoint. `generate=true` also returns the plaintext once, because the operator has to be able to write it down — a LUKS passphrase that nobody knows makes the data unrecoverable.

The JSON body carries:

- `value` (string, required)
- `generate` (true or false, optional, default `false`)
- `length` (whole number, optional, default `24`)

#### `GET /api/v1/vault/secrets`

Every encrypted secret reference held in the vault — scope variables and config-policy values whose stored value is a `vault:v1:` handle. Returns the location (scope/policy + key) and NEVER the plaintext.

---

## activity

What happened recently, as an operator's timeline.

#### `GET /api/v1/activity/running`

Count + a small list of currently in-flight jobs (plan runs, PXE restores, rollouts). Drives the header Event-Console badge — `count` is the badge number, `jobs` a preview for the hover/click-through.

---

## config-codecs

Which configuration files this system can parse, and with which grammar.

#### `GET /api/v1/config-codecs`

The whole codec registry as a flat list, one entry per pattern: [{pattern, codec, confidence, comment, separator, notes, sections, paths, packages}]. Also a `summary` with per-codec / per-confidence counts so the UI can show catalog stats without re-counting.

---

## config-directives

Per-key knowledge for parsable configuration files: types, defaults and allowed values.

#### `GET /api/v1/config-directives`

The whole directive-value catalog: {file: {directive: spec}}. Empty (available:false) until the mining batch has produced the file.

---

## health

Is this server alive. No token needed.

#### `GET /healthz`

Healthz. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

---

## package-catalog

Every package this system knows configuration for.

#### `GET /api/v1/package-catalog`

{packages: {name: {label, category, icon, description, template, validate_cmd?, families:{debian,redhat:{packages,service,config_path}}}}}.

---

## package-qualify

The batch that classifies a package's configuration files.

#### `POST /api/v1/packages/{name}/qualify`

Create every config artifact for one package (codec/directives/template/enum) + categorize it. Runs the same qualify pipeline the host batch uses. `force=true` clears this package's markers first, so an already-qualified package is rebuilt instead of reported as already current.

In the path:

- `name` (string, required)

Query parameters:

- `force` (true or false, optional, default `false`)

---

## package-wizard

Guided setup for one package's configuration.

#### `GET /api/v1/agents/{agent_id}/package-wizard/context`

Wizard Context. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

In the path:

- `agent_id` (string, required)

Query parameters:

- `refresh` (true or false, optional, default `false`)

---

## relationships

Dependencies between objects, used to explain an outage by its cause.

#### `GET /api/v1/relationships`

List Relationships. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `agent_id` (string, optional) — Limit to edges originating from this agent
- `raw` (true or false, optional, default `false`) — Also return the underlying edges, busiest first
- `limit` (whole number, optional, default `200`) — Max groups (and raw edges) returned

---

## topology

How hosts are connected, as measured rather than as drawn.

#### `GET /api/v1/topology/graph`

Topology Graph. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

Query parameters:

- `refresh` (true or false, optional, default `false`) — Bypass the short-lived cache and rebuild

---

## translate

Turning a catalogue specification into something an agent can execute.

#### `POST /api/v1/translate`

Translate Route. _(No further description in the source — the handler has no docstring, so this is all the server itself says about it.)_

The JSON body carries:

- `chunk_name` (string, required)
- `plan_name` (string, required)
- `source_text` (string, required)
- `max_retries` (whole number, optional, default `2`)
- `threshold` (number, optional)

---

## What this page does not cover

- **The agents' own HTTP API.** Each agent serves `/healthz`, `/api/v1/tools`, `/api/v1/audit` and
  the module invocation endpoint on its own port (8051 for the Go agent, 8451 for the Windows one),
  behind mTLS. You normally reach it *through* Bossman, and the module pages describe what it offers.
- **The MCP tool surface.** The same actions are exposed to models as MCP tools; the developer guide
  says which ones and how they map onto these endpoints.
- **WebSocket endpoints**, which do not appear in an OpenAPI document. The web shell and the live log
  tail use them.

