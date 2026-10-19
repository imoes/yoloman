# CODE CARD — agentic-mcp (Bossman + Duppy)

> **THE PROJECT'S CORE IDEA: every host task is a MODULE.** Don't reinvent as bespoke shell/Python — the
> agent already ships ~700 modules (≈2000 counting every collection variant) for partitioning, LVM,
> filesystems, mounts, network, hostname, timezone, users, packages, services. **Look for a module first**
> (`agentic-mcpd run-module --list`, `--modules-dir configs/modules.d` for the discovered set; or MCP
> `tools/list` / `GET /api/v1/modules`). **And if a task has NO module yet — build one** (a native Go
> module in `internal/modules/`, or a Starlark module). That is the whole point of the project: the fleet
> is driven by a growing, reusable module library, not one-off scripts.

## The three pieces

| Piece | Path | What it is |
|---|---|---|
| **Bossman** | `bossman/` | The fleet commander / control plane. FastAPI + SQLAlchemy async + PostgreSQL/TimescaleDB. API in `bossman/bossman/api/`, logic in `services/`, ORM in `db/models.py`, migrations in `alembic/`. |
| **Duppy (agent)** | `cmd/agentic-mcpd/` + `internal/` | Go daemon on each host. Serves **MCP** (HTTP/stdio) + **REST** (`/api/v1/…`). Runs **modules** and **checks**. mTLS; Bossman polls it. |
| **UI** | `bossman-ui/` | Angular 20 (standalone components, signals, Material). Served separately; talks to Bossman's REST. |

## Modules — the heart of it (USE THESE)

A **module** = one idempotent task with `Run(ctx, params, dryRun) → {changed, msg, data}`. Three sources,
one registry (`server.NewDefaultModuleRegistry()` + loaders), one dispatch (MCP tool ≙ REST task ≙ CLI):

1. **Native Go** — `internal/modules/`: `command`, `apt`, `apt_key`, `apt_repository`, `copy`, `template`,
   `blockinfile`, `assemble`, `systemd`, `config`, `config_discover`, `firewall`, `storage_facts`, …
2. **Embedded Starlark** — `internal/starmodules/embedded/modules/yoloman/`: `network_interface`
   (auto-detects **NetworkManager / netplan / systemd-networkd / ifupdown** and writes to the right place),
   storage stack, checkpoint. Baked into the binary (`go:embed`), always present.
3. **Discovered Starlark** — `configs/modules.d/` (~693 `.star`): translated Ansible collections
   `ansible.builtin`, `community.general`, `posix`, `community.crypto`, `community.docker`. Includes the
   provisioning workhorses: `community.general.parted`, `.lvg`, `.lvol`, `.filesystem`, `posix.mount`,
   `community.general.interfaces_file` (ifupdown), `.nmcli`, `.timezone`, `.locale_gen`, `ansible.builtin.user`,
   `.hostname`, `.copy`, `.template`, … Loaded from `modules_dir` (`starmodules.LoadDir`). Pushed/updated via
   `POST /api/v1/modules/apply`.

**Exposed as:** MCP tools (`internal/server/modules.go` `RegisterModules`), REST task dispatch, and
**`agentic-mcpd run-module <name> --json '{…}' [--modules-dir DIR] [--dry-run] [--list]`** (offline CLI —
loads native + embedded + discovered — for running any module inside a chroot). Modules that mutate a
running host (e.g. `network_interface` runs `ifup`/`netplan apply`) accept **`"apply": false`** to write
config only — used by the offline provisioner, where the target isn't running yet.

**Distributing the discovered set — Bossman pushes on demand.** A Duppy does not ship the 693 `.star`
library; Bossman delivers them over mTLS with **`POST /api/v1/agents/{id}/modules/sync`** (`api/agents.py`
`sync_agent_modules` → `agent_client.push_modules` → the agent's `POST /api/v1/modules/apply`, which
validates + persists + live-registers them into `ModulesDir`). Body `{fqcns: [...]}` for a subset, or none
for the whole translated library. **It requires a running, directly-addressable agent** — a satellite/
unenrolled host has no address and returns 409.

**Embed vs. push — how a module reaches the bare-metal restore path.** The **PXE container runs a
Bossman-registered agent** (`deploy/pxe/entrypoint.sh`, mirrors the poller: self-enrols, `write:true`), so
Bossman CAN `/modules/sync` the discovered library to it. The catch: sync lands the `.star` in the
*container's* `ModulesDir`, but the **target** restore runs the **RAM-PE**, and `deploy/pxe/build-pe.sh`
must **bake that ModulesDir into the PE squashfs** for `run-module --modules-dir` to see it in the target
chroot. So two valid delivery routes, pick by how fixed the module is:
- **Embedded** (native Go / embedded Starlark, baked into `agentic-mcpd`): always present in the PE, zero
  wiring, no push/bake step. Right for the tiny always-needed set — `yoloman.network_interface`,
  `yoloman.machine_identity`, and the storage stack (lvg/lvol/filesystem) already embedded.
- **Pushed + baked** (Bossman `/modules/sync` → PXE container `ModulesDir` → baked into the PE by
  build-pe.sh → `run-module --modules-dir`): the broad discovered library (parted, mount, timezone,
  locale_gen, …) without reimplementing any of it in Go. This is the planned path and is the reason the
  PXE agent is registered at all — **but the build-pe.sh baking step is the missing wiring today.**
- **Day-2** (a live, enrolled host) → discovered + synced on demand, no PE involved.

**Manual pages for the model (`manpage`).** The agent's read-only `manpage` module searches (`query`, `full_text`)
and reads (`page` + `section`, `heading`, `grep`, `max_chars`) the man pages installed on the host — the
documentation of exactly its versions, rendered natively from roff/mdoc (no man-db/groff needed); a host without
pages says so in `note`. It is an MCP tool of the agent itself; Bossman forwards it as `man_search(host, …)` on its
MCP server and in the in-app assistant (`services/manpages.py`), and the operator guide sends a model there before
it changes a setting it would otherwise guess.

## Explainable diagnosis (`docs/diagnosis.md`, plan `docs/diagnosis-plan.md`)

- **Contract:** `configs/schemas/diagnosis.schema.json` (evidence with stable ids, findings with rule/certainty
  Proven|Likely|Unknown/evidence_ids/precedent/remedy-as-data/gap, timeline, gaps); rules `configs/diagnosis_rules.json`
  (one name per cause on both platforms); goldens `configs/schemas/diagnosis.examples/`; the one document check
  `bossman/bossman/services/diagnosis_contract.py` (schema + cross-checks, named violations).
- **Linux agent:** `internal/diagnosis` (model, Builder that refuses forbidden findings, Validate, embedded catalogue
  kept identical to configs/ by a test; `CollectSystemd` → `SystemdSnapshot` → `DiagnoseSystemd`, rules are pure
  functions over the snapshot). Module **`service_diagnose`** (read-only): `{name, include_snapshot}` →
  `data.diagnosis`. An empty journal is a named gap, not silence. `journal` entries now carry `cursor`,
  `invocation_id`, `message_id`.
- **Windows agent:** `windows-agent/AgenticMcp.Agent.Diagnosis` (net10.0, no Win32: model, Builder, Validator,
  `WindowsRules` over `WinServiceSnapshot`) + `AgenticMcp.Agent.Windows/Diagnosis` (`ScmCollector`: SCM, event log by
  id/EventData, service key LastWriteTime; `AccountCollector`: SID, SAM, LSA rights, AuthzAccessCheck). Same module
  name `service_diagnose`.
- **Precedent:** `Builder.Change/Precede` in both languages — newest change before the failure within 7 days, target
  before host (Linux: ctime of unit/drop-in/program, dpkg.log / rpm; Windows: key LastWriteTime, image, 7045/7040,
  MsiInstaller / WindowsUpdateClient 19).
- **Bossman:** `services/diagnosis.py` (ask → re-check → store; violation stored, never repaired; 404 → named
  refusal), table `diagnoses`, REST `POST /api/v1/agents/{id}/diagnose`, `GET /api/v1/agents/{id}/diagnoses`,
  `GET /api/v1/diagnoses/{id}`, MCP `diagnose_service` / `recent_diagnoses`, chat tool `diagnose_service`.
- **Probes on real hosts:** `tools/diagnosis_probe_linux.py` (pods, both families), `tools/diagnosis_probe_windows.py`
  (bossman-wintest through Bossman; `--repair` applies the PowerShell export, verifies, rolls back; builds and stages
  `windows-agent/AgenticMcp.Agent.ProbeService` for exit-code/crash/hang), results in `configs/diagnosis_probe_*.json`.
  Cross-check against the package-e2e classifier: `package_e2e_bossman --baseline` writes `diagnosis_compared`
  (agrees / agent-more-specific / disagrees) per row.
- **Windows Update in the console:** snap-in `updates` serves both families through the requirement `any_of`
  (`api/mmc.py`); Windows nodes read `windows_update_facts`, the install action calls `windows_update`.
- **Exports (Bossman only):** `services/diagnosis_export.py` — checkmk / gelf / ansible / dsc / powershell,
  `GET /api/v1/diagnoses/{id}/export/{format}`, MCP `export_diagnosis`; `not_expressible` names what a format cannot
  say. `diagnosis_probe_windows --repair` applies the PowerShell export on the host, verifies, rolls back.
- **Remedy → proposal:** `services/proposals.create_remedy_proposal` (kind `remedy`), four-eyes via `approvable`,
  approval records + attaches artifacts and never executes; `POST /api/v1/diagnoses/{id}/propose`, MCP
  `propose_remedy`; proposal API returns `can_approve` / `cannot_approve_reason` per caller. E2E:
  `bossman-ui/e2e/diagnosis.spec.ts`.
- **Explanation:** `services/diagnosis_explain.py` — `explain()` (model or template), `check()` (backed/why per
  sentence), `header()` (code-written certainty/precedent/remedy/gaps); `GET /api/v1/diagnoses/{id}/explain`, MCP
  `check_explanation`.
- **UI:** `bossman-ui/src/app/features/diagnosis/diagnosis-panel.component.ts`, opened from the Services snap-in row
  action "Why is it not running?" (`configs/mmc_snapins.json`, `view: "diagnosis"`); the console greys a row action
  whose module the host does not publish. E2E `bossman-ui/e2e/diagnosis.spec.ts`.
- **Windows updates (B13):** agent modules `windows_update_facts` (read) and `windows_update` (write; pure halves
  `AgenticMcp.Agent.Modules/WindowsUpdate{Facts,Selection,Run}.cs`); Bossman `CveFeed` reads MSRC CVRF (KB → CVE),
  `cve_correlate.correlate_windows`, `cve_collect` reads Windows hosts through `windows_update_facts`,
  `/api/v1/security/bulk-update` installs the CVE-closing KBs (`kbs` to choose).
- Still to come: install the OS cumulative update for real (operator's decision), "Windows Update" snap-in, patch rings.

## Config system (not modules, but adjacent)

- **config-templates** — `configs/config_templates/<name>/` = `template.j2` (gonja/Jinja2) + `schema.json`
  (typed fields) + `sample.json` + `capabilities.json`. DB-bound to hosts, edited as VALUES in the WebUI.
  `GET /api/v1/config-templates` LISTS them (name + `target_path`, no bodies); `…/{name}` returns the one.
  Bossman serves the whole tree; the AGENT PACKAGE ships only what a request can name — 1050 of 5474, staged
  by `scripts/stage-agent-templates.py`, which asserts closure and records the rest in
  `configs/config_templates_manifest.json` so the listing can say what it withheld. The managed write path
  needs none of it: a template resource carries its body inline (`internal/state/state.go:43`).
- **config codecs** — `configs/config_codecs.json`: parse⇄generate real config files (man-page-derived).
- **checks** — `configs/checks.d/`: Starlark monitoring checks (Checkmk-translated + custom).
- **who owns it** — `configs/config_unowned_paths.json`, from `find_unowned_base_files.py` run in a base
  image: the files `dpkg -S` / `rpm -qf` disclaim, i.e. created by the installer or the base system. The
  guard that keeps `/etc/hostname` editable; container-only artifacts are recorded but earn no exemption.
- **does the file exist** — `configs/config_path_verdicts.json` (per path: file|directory|dangling-symlink|
  absent + whether a maintainer script creates it), measured by `bossman/scripts/verify_registry_paths.py`
  in a container against the real `.deb` and recorded by `record_path_verdicts.py`. Driver:
  `scripts/verify-registry-paths.sh` (resumable, one process, flock). Separate from the codec registry on
  purpose: that answers how a file is written, this whether there is a file, and the qualify batch rewrites
  the former knowing nothing about the latter.
- **was the grammar tested** — `configs/codec_probe_verdicts.json` (per path: verdict + active_lines + keys),
  written by `decide_codecs.py --record`. Separates "nobody has looked" from "probed, and the file could not
  decide": all 81 unmeasured claims whose real file is in the corpus came back `no-evidence`, because the
  shipped `/etc/security/limits.conf`, `/etc/sysctl.conf` and 79 others are entirely comments. First is a
  task, second is a dead end for this method — and `/config-fields`'s provenance note now says which.
- **the qualify pipeline** — `bossman/bossman/tools/` (in the package, shipped): `qualify_packages` (codec →
  directives → template → enum, per-package, resumable), `build_package_catalog` (which calls
  `curate_catalog` itself — a rebuild without the curation strips the checked RedHat facts from 24 entries),
  `enrich_gates`, `mine_directive_values`, `classify_config_codecs`, `batch_verify`. Run the batch with
  `python -u -m bossman.tools.<name>`; ONE package on demand goes through `qualify_one()`, which
  `POST /api/v1/packages/{name}/qualify` (+ the MCP tool) calls IN PROCESS and reports from its return —
  `already_current`, the codec, enums/directives mined, and `detail` for a skip or an unreachable LLM.
  `?force=true` clears that package's markers first. Paths come from `tools/_paths.py`, which FINDS the repo
  root rather than counting `parents[2]` — that constant differed between the container and a checkout, which
  is why a patched duplicate of every tool used to live in the untracked `bossman/scripts/`.
- **package e2e + template hygiene** — `tools/package_e2e_worklist.py` (one route per package),
  `tools/package_e2e.py` (agent in a fresh pod per package), `tools/package_e2e_bossman.py` (every catalog role
  through the role-deployment API on a fresh systemd host; `--baseline` starts the unit with the SHIPPED file and
  `--classify` names the cause from the journal; unavailable families recorded as such). Report:
  docs/package-config-e2e.md. Sweeps the qualify pass also applies per package: `tools/normalize_schema_types`
  (defaults/enums/samples in the field's type, object/list defaults) and `tools/ensure_template_newlines`.
  `tests/test_catalog_templates_agent_parity.py` renders every catalog template under the agent's gonja
  (`bossman/bin/render-check`, rebuild it after agent filter changes) and jinja2 — they must agree. A hand-built
  template carries `meta.json source: "hand"` (or sits in `qualify_packages._CURATED`): `_curated()` keeps the batch
  from regenerating it. `template_repair_chain` ends with `activate_expressions` (a commented setting becomes live
  when set, the shipped line when unset); guards use `activate_commented_settings.present()` because gonja treats
  `[] != []` as true. A template field marked `required` is required in the wizard (form `*`, Validate/Install
  greyed with the reason) and the preview's 422 names every missing value; the e2e takes test site values from
  `configs/package_e2e_site_values.json`. Catalog `families.<f>.init` closes packaging gaps once (service user,
  state dir, unit drop-in); `DEBIAN_FIXES config_path ""` = "installed, not configured" (never refilled).
  **Stage 5 + repair** (plan: docs/package-config-e2e-plan.md): `tools/template_shipped_fidelity.py` renders every
  reachable (template, family, path) with its defaults through the agent's engine and compares with the file the
  package ships (`configs/template_shipped_fidelity.json`; incremental — a template changed after its verdict is
  measured again). `tools/repair_from_shipped.py` runs `template_repair_chain` per `differs` unit and keeps a repair
  only if EVERY unit of the template gets closer and the sample renders; catalog templates only with `--catalog`
  (then run the roles for real); a runtime revert in `configs/template_shipped_repairs.json` is a permanent veto.
  `tools/template_from_shipped.py --names-from <role template dir>` builds a (family) template from a shipped file
  with the role's field names — defaults reproduce the file by construction. `tools/probe_checkers.py` admits a
  package checker to `configs/package_validators.json` only after it accepted the SHIPPED file on a fresh test host.
  `batch_verify.verify_template` refuses `for k, v in X | dict2items` (gonja renders `key = value`; qualify rewrites
  it to `| dictsort`); `batch_verify.null_safe_objects` guards attribute chains on unset objects.
  **Family fields:** a role's runbook parameters are the union of its templates; family-only fields carry
  `families: [...]` (wizard greys them out on other families; the engine refuses a set value there via
  `_family_only`). Index: the catalog is a record of its role template's file (no namesake bindings); a template
  recorded for another family is withdrawn from a family's index (`other-family`); gate-refused templates with a
  target are listed as `not-configurable`; a binding stage 5 measured as `wrong-file` (tools/explain_differs: not one
  setting the template writes occurs in the shipped file, which has settings) is withdrawn per family — catalog
  bindings excepted (fix those); the reason stays recorded while the template's hash is unchanged, so the index does
  not re-bind it. Checkers: runners use only `verified…` entries of package_validators.json;
  `probe_checkers --mined` probes mined ones (counter-probe first, no file written under /etc, /var/lib, /var/spool,
  /srv, /opt, /root, /home). Qualify leaves catalog templates and meta `hand`/`repaired` alone. E2E worklist routes: wizard / rule-template /
  rule-codec / no-config / `replaced` (repo Obsoletes, `tools/rpm_replacements` → configs/package_replacements.json) /
  unrouted; a directory is never a route; the runner counts a result only for its own route. The index refuses key
  material and trust anchors (.der/.pem/.asc/trusted.gpg.d). Agent: codec lookup matches the same path of another release
  (versionless); a unit with RefuseManualStop restarts via the package's legacy action; a failed command's error
  carries stdout's cause lines. **Role files (G2):** `families.<f>.files: [{path, field, mode, owner, group, secret}]`
  → a multi-line field (`widget: text`, masked when `secret`) and a `copy` step after the render
  (`wizard_seed._with_files`).
- **one field spec, two servers** — `GET /api/v1/config-fields?path=` is the single describe() for a config
  file (`write: codec|template|freeform|unknown` + typed `fields`). Bossman computes it from the rules
  (`bossman/bossman/api/config_fields.py`); a STANDALONE agent serves the same answer from recorded
  projections (`internal/server/management_config_fields.go`) so no rule exists twice. The projections are
  written by `bossman/scripts/export_agent_config_projection.py --write` — rerun it after mining, or the host
  serves yesterday's catalog — and agreement is MEASURED by `scripts/diff-agent-config-fields.sh` (91/121
  paths, both families, every key equal). Same for `/config-generated` and `/config-templates/index`.

## Authoring format: Ansible task syntax, and only that

Runbooks, roles and plans are written in real Ansible task syntax (`services/ansible_playbook.py`) — the
only text format the system reads or writes. A **role** is the same syntax under a `role:` key plus
`monitoring.checks` / `notifications.routes`; a **runbook** may add `targets:`. Both parse into the canonical
JSON document (`services/nt_runbook.py` — the doc model + validator, despite the `nt_` name).

A NestedText authoring surface existed beside it and was removed (`docs/nestedtext-removal.md`). Keeping two
grammars caused three real bugs, all fixed with it: NT was used as an internal round-trip just to reach the
validator; a stored **role** re-validated as a *runbook* (losing its checks/routes, and slipping past the
"that is a role, not a runbook" guard) because only the authoring key `role:` was recognised, not
`kind: role`; and the `${var}` shim rewrote `$word` in *every* string, so `echo $HOME` failed and
`awk "{print $2}"` was silently corrupted. Templating is Jinja2 only (`services/nt_vars.py`, sandboxed,
StrictUndefined).

`nt_engine` / `nt_vars` / `nt_compile` keep their names but parse no NestedText — they are the run engine,
variable substitution, and the role→OrchestrationPlan compiler. Still NestedText today: the **argspec
sidecars** (`configs/checks.d/*.nt`, `configs/modules.d/**/*.nt`, `*.provision.nt`) — metadata, not an
authoring format; conversion to YAML is part B of the removal doc, and the Go agent already reads `.yaml`
sidecars (`internal/starmodules/loader.go`).

## Plans vs. runbooks — two stores with different surfaces

Both hold "a list of steps", and which one an import belongs in is decided by *how much Ansible it uses*:

| | **Runbook** (`runbooks` table) | **Plan** (`plan_documents`) |
|---|---|---|
| Parser | `services/nt_runbook.py`, `services/ansible_playbook.py` | `services/plan_loader.py` |
| Engine | the Go runner (`internal/runbook/`) | the orchestration engine |
| Step shape | `{module, args, …}` | `{name, <module>: {args}}` (module-as-key) |
| Task vocabulary | **full**: `block`/`rescue`/`always`, `when`, `loop`, `register`, `notify`, `tags`, `become`, `failed_when`, `changed_when`, `ignore_errors`, `key=value` free-form | narrow: `when`, `loop`, `register`, `check_mode`, `on_failure` + `pipeline`/`upload`/`assert` |

Measured on `geerlingguy.nginx`: the runbook parser accepts **10 of 10** task files, the plan loader 4 — so
**Ansible imports go to the runbook store**, Salt/Puppet/Chef to the plan store (their parsers emit plan
bodies). `POST /api/v1/plans/import-bulk` routes on that rule; see `docs/orchestration-import.md` for the
per-framework coverage measurements and the remaining parser gaps.

- **Bulk / directory import** — `POST /api/v1/plans/import-bulk` `{files:[{path,text}], folder, dry_run}` →
  `{imported:[{path,prefix,name,version,kind,status?}], skipped:[{path,reason}], failed:[{path,error}]}`
  (`status` created|updated|unchanged for runbooks; a name taken in another folder is refused, not overwritten). Classifies
  each path itself (`plan_store.detect_plan_format`, positive dir+ext rules), isolates failures per file, and
  `dry_run` parses without writing so a preview cannot claim a file is importable when it isn't. UI: the
  "Import" panel of the plan library (`features/plans/plan-library.component.ts`), directory picker.

## Role deployments + role bindings (`docs/role-deployments.md`)

- **Artifacts**: catalog roles (`catalog__<pkg>`) and saved `role:` documents are versioned `OrchestrationPlan`s;
  `POST/PUT /api/v1/runbooks` for a role returns `artifact:{id,name,version}`. Version list + diff:
  `GET /api/v1/orchestration/plans/{id}` (`versions`), shown with `shared/version-diff` (the one diff view,
  also used by the plan library).
- **Deployments** (`api/role_deployments.py`, `services/role_deployment.py`): `GET /role-artifacts`,
  `POST /role-deployments/preview` (targets host|group|ou|site|global; `applicability[].not_applicable` +
  `substituted`), `POST /role-deployments` (preview_hash, `require_approval`), `/approve` (four-eyes),
  `/reconcile`, `/remediate`, `/retire`, `/targets/{id}/remove`. Detail: targets carry `host`, `last_error`,
  `waiting_for` (pilot gate); items carry `uninstall_blocked`. UI: Deploy → Roles & Features.
- **Bindings**: host Management → Role bindings (`ResourceNode` kind role) → `OrchestrationPlanLink`
  (`created_by` = requester). Approval queue: `GET /api/v1/orchestration/pending-links` (with `plan_name`,
  `target_label`), approve = admin and not the requester; UI: Deploy → Change proposals, "Role bindings awaiting
  approval".
- E2E: `bossman-ui/e2e/roles.spec.ts` (A1–A6), `e2e/deployments.spec.ts` (B1–B14), helpers
  `e2e/support/deploy-scenario.ts` (incl. a cross-worker lock for YOLO / write-gate scenarios).

## PXE bare-metal imaging (the current build)

- **Capture / import**: `services/imaging.py` (pure plan) + `api/images.py` + `deploy/pxe/import-image.sh`
  (in the pxe container: qemu-nbd a CoW overlay → partclone each fs volume → DiskImage = manifest + files).
  LVM is filter-scoped to `/dev/nbd*` (`/etc/lvm/lvm.conf`) so the privileged container never touches the
  host's disks.
- **Restore**: PXE (dnsmasq DHCP+TFTP, gated on a pending job) → RAM PE (`deploy/pxe/build-pe.sh`, Debian +
  systemd + partclone/lvm2/fdisk) → `pe-init.sh` checks in → `restore_steps` (require-blank-disk →
  **disk_partition** → lvm → **partclone_restore** → grow → **bootloader** firmware-aware BIOS/UEFI →
  **initramfs** → **machine_identity** → **network** → offline-enrol) → one reboot. `deploy/pxe/entrypoint.sh`
  runs the agent so the container is a managed host.
- **Provisioning modules** = `deploy/pxe/provision-modules/yoloman/` (disk_partition, partclone_restore,
  bootloader, initramfs, machine_identity): one-shot deploy ops, so they are **baked into the PE**
  (build-pe.sh), NOT the builtin agent. The restore drives them via `run-module --modules-dir` — PE-level
  steps (partition, restore) use the PE's baked copy; chroot-level steps (bootloader, initramfs, identity)
  use the agent + modules staged once into the target. network → `yoloman.network_interface` (embedded, it's
  a general day-2 capability). LVM stays on embedded lvg/lvol. Add a new provisioning op → a `.star` here.

## Kubernetes console (project kubernetes-console — `docs/kubernetes-console.md`)

- A **Kubernetes cluster** (`KubernetesCluster`, `/api/v1/kubernetes/clusters`) is registered by its **access
  host**: the enrolled agent holding `kubectl` + kubeconfig. Bossman stores no credential and never touches
  etcd — every read/write is agent → `kubectl` module (`internal/modules/kubectl.go`) → API server.
- **Resource kind `k8s`** (`services/resources/kubernetes_object.py`): observe/plan/apply/rollback + `DELETE
  …/object` for ONE object, under `/agents/{id}/resources/k8s/{name}/…?cluster=&namespace=&api_version=&object_kind=`.
  apply = server-side apply, field manager `bossman`, a generation; gated by YOLO/ChangeProposal (kind
  `kubernetes`); plan = `apply --dry-run=server` + `kubectl diff`.
- **The Application form** (`services/kubernetes_app.py`, `POST …/applications/{render|plan|apply}`): form →
  manifests in apply order; the kind is derived; validation against the inventory; one proposal per application.
- **Explorer data** (`services/kubernetes.py`): inventory cache on the cluster row (poller, 15 min), lists with
  the ten-state vocabulary + reasons (`configs/kubernetes_reasons.json`), events, logs, actions.
- MCP: `k8s_clusters/inventory/objects/object/events/logs/plan/apply/generations/rollback/delete`.
- UI: Fleet → Kubernetes clusters (`features/kubernetes/`): registry, explorer, wizard.

## Kernel tuning (`docs/kernel-tuning.md`)

- The LLM chooses and parameterises from a catalogue (sched_ext `scx_*`, sysctl, cgroup, readahead, governor,
  cmdline); it never writes scheduler code. Plan blocks 1–8 in the doc.
- **Kernel capabilities** (`internal/kernelcaps`, block 1): btf, `CONFIG_*` flags (from `/proc/config.gz`, otherwise
  `/boot/config-<release>`), sched_ext state + attached ops, boot loader (`uki|systemd-boot|grub|extlinux|unknown`),
  init system (`systemd|openrc|unknown`) and the eBPF collector load result (`loaded|failed|disabled|not_started`).
  Each is a named state with evidence. Exposed as the setup fact `yoloman_kernel_caps` (no ansible_ alias) and as
  `kernel_caps` in `GET /api/v1/hosts/overview`.
- **Comparable observation** (block 2): per-interval series `runq_latency_us_bucket{le}` (delta of the cumulative
  BPF map), `oom_kill_total`, `signal_total{signal}`. Collect loop in `cmd/agentic-mcpd/main.go`.
- **Tunable modules** (block 3, embedded `yoloman.*`): `sched_ext`, `systemd_resource`, `blockdev_tuning`,
  `cpu_governor`, `kernel_cmdline`. One result shape: `before/after/persistence(live|persistent|pending_reboot)/backend/rollback`.
  The rollback is one call that restores the previous state exactly. Refusals are prefixed `unsupported:`,
  `tool_unavailable:` or `conflict:` and happen before any change. Tests: `embedded/tunables_test.go` (fakeHost).
- `ctx.facts()` carries `kernel_caps`; the OS family comes from one table, `internal/osfamily`, shared with setup.
- **Tunables as desired state** (block 4): resource kind `tunable` (`services/resources/tunable.py`, `TUNABLES` is
  the list), names `<tunable>[:<target>]`, `desired={"params":{...}}`; generations store `params` + the module's
  `undo`; `rollback(0)` = the state before yoloman managed it. The MCP `resource_*` tools now build through the
  registry (`services.resources.build`) — all eight kinds.
- MCP `update_agent(host, dry_run=True)` = REST `update-bundled`, one implementation in `services/agent_update.py`.
  The host ACL is checked by `_authorize_host` (via `mcp.auth.current_auth_identity`, the token's UID) in
  `_addressed_agent_or_raise`, `_make_resource`, run_plan, run_runbook and update_agent; DB-only reads and
  monitoring writes stay open, like REST. Tests calling tools directly act as admin (`tests/conftest.py`).
- **VM deployment over MCP**: `vm_hosts`, `check_ip`, `suggest_free_ips`, `deploy_vm`, `deployment_status` —
  `services/vm_provision.py` (shared with REST auto-provision), `services/ip_check.py` (Bossman records + NetBox
  `BOSSMAN_NETBOX_*` + live ping/ARP via an agent in the subnet).
- `yoloman.benchmark`: one run of one profile per call; experiments alternate runs in Bossman.
- **Experiments** `services/experiment.py` + table `tuning_experiments` (migration a7d3e9c5f1b2): MCP `experiment_start/status/experiments`, REST `POST /api/v1/agents/{id}/experiments`, `GET /api/v1/experiments/{id}?wait_s=`; verdict = exact Mann-Whitney U (p<0.05) + 2 % min effect; `snapshot=true` = Proxmox rehearsal (`vm_snapshot/_rollback/_delete`).
- **scx bundled**: `scripts/build-scx.sh` → `deploy-artifacts/scx/<ver>/` → packaged at `/usr/lib/yoloman/scx/<ver>/` by build-agent-deb.sh; scx_install `source=auto|bundled|upstream`.
- `yoloman.scx_install`: builds scx (pinned tag, default v1.1.4) as transient unit `yoloman-scx-build-<ver>` into `/opt/yoloman/scx/<ver>/bin`, links `/usr/local/bin/scx_*`; states built|building|absent; build tools are tool_unavailable (install with the package module). Verified: Ubuntu 26.04, 4 min, then scx_bpfland attached.
- **PXE DHCP policy** `services/netboot_dhcp.py` (restricted to armed MACs | open window for a MAC-less job | off),
  carried by `/netboot/config`; the entrypoint writes `dhcp-host` + `dhcp-ignore=tag:!known` and picks the UP
  interface holding `PXE_LISTEN_IP`.
- **Netinstall** `services/netinstall.py` + table `netinstall_jobs` (migration c3f7a9e1d2b4): `deploy_vm(install="fedora")`
  → kickstart, per-MAC pxelinux entry, local stage2; done = first agent report. `BOSSMAN_NETINSTALL_HTTP_BASE`.
- MCP `set_netboot` (all grant, shared `api.system_settings.apply_netboot`), `vm_status`, `vm_power`.
- `python -m bossman.tools.mcp_agent`: model-over-MCP probe harness (tool subset, JSONL log, no max_tokens).
- **Install wizard** (UI Deploy → Install hosts, `/vm-deployments`; Disk images → New deployment opens it too — the old provision-wizard is gone): `features/vm-deploy/` +
  `core/services/vm-deploy.service.ts` over REST `api/provision_deploy.py` — `GET /api/v1/provisioning/catalog`,
  `GET installs/{install}`, `POST check-ip`, `GET suggest-ips`, `POST deploy` (dry_run default; 409 + checks),
  `GET deployments` (list), `GET deployments/{hostname}`. Same `vm_provision.deploy` as MCP `deploy_vm` (ai=False:
  a person may apply the finalization without YOLO). e2e: `bossman-ui/e2e/vm-deploy.spec.ts` (V1–V6; V7 real
  deploy only with `E2E_REAL_DEPLOY=1`).

## Deploy / run

- Stack: `docker compose --profile pxe up -d --build` (project `agentic-mcp`). Host-specifics in
  `docker-compose.override.yml` (gitignored). Bossman published on `host4.example.internal:8123`, UI on `:4201`.
- Agent build: `scripts/build-agent-deb.sh` → `deploy-artifacts/agentic-mcpd` + `agent.deb`/`.rpm` (the pxe
  Dockerfile + the offline installer copy these in).
- Plans live in `docs/` (one file per project). This card is the architecture map; keep it current.
