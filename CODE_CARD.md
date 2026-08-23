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
  `{imported:[{path,prefix,name,version,kind}], skipped:[{path,reason}], failed:[{path,error}]}`. Classifies
  each path itself (`plan_store.detect_plan_format`, positive dir+ext rules), isolates failures per file, and
  `dry_run` parses without writing so a preview cannot claim a file is importable when it isn't. UI: the
  "Import" panel of the plan library (`features/plans/plan-library.component.ts`), directory picker.

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

## Deploy / run

- Stack: `docker compose --profile pxe up -d --build` (project `agentic-mcp`). Host-specifics in
  `docker-compose.override.yml` (gitignored). Bossman published on `host4.example.internal:8123`, UI on `:4201`.
- Agent build: `scripts/build-agent-deb.sh` → `deploy-artifacts/agentic-mcpd` + `agent.deb`/`.rpm` (the pxe
  Dockerfile + the offline installer copy these in).
- Plans live in `docs/` (one file per project). This card is the architecture map; keep it current.
