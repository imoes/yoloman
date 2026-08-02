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
- **config codecs** — `configs/config_codecs.json`: parse⇄generate real config files (man-page-derived).
- **checks** — `configs/checks.d/`: Starlark monitoring checks (Checkmk-translated + custom).

## PXE bare-metal imaging (the current build)

- **Capture / import**: `services/imaging.py` (pure plan) + `api/images.py` + `deploy/pxe/import-image.sh`
  (in the pxe container: qemu-nbd a CoW overlay → partclone each fs volume → DiskImage = manifest + files).
  LVM is filter-scoped to `/dev/nbd*` (`/etc/lvm/lvm.conf`) so the privileged container never touches the
  host's disks.
- **Restore**: PXE (dnsmasq DHCP+TFTP, gated on a pending job) → RAM PE (`deploy/pxe/build-pe.sh`, Debian +
  systemd + partclone/lvm2/fdisk) → `pe-init.sh` checks in → `restore_steps` (require-blank-disk → sfdisk →
  lvm → partclone restore → grow → grub **firmware-aware BIOS/UEFI** → identity/hostname → **network** →
  offline-enrol) → one reboot. `deploy/pxe/entrypoint.sh` runs the agent so the container is a managed host.
- **The provisioning TODO**: the configure phase (network, hostname, timezone, users, packages) should run
  MODULES via `run-module` in the chroot, not bespoke shell. Network already targets `yoloman.network_interface`.

## Deploy / run

- Stack: `docker compose --profile pxe up -d --build` (project `agentic-mcp`). Host-specifics in
  `docker-compose.override.yml` (gitignored). Bossman published on `host4.example.internal:8123`, UI on `:4201`.
- Agent build: `scripts/build-agent-deb.sh` → `deploy-artifacts/agentic-mcpd` + `agent.deb`/`.rpm` (the pxe
  Dockerfile + the offline installer copy these in).
- Plans live in `docs/` (one file per project). This card is the architecture map; keep it current.
