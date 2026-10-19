# Changelog

What yoloman can do that it could not do before — grouped by effect, not by file. Commits explain changes to
code; this explains changes to the **product**.

**Every entry names its evidence.** "Verified on the real host", "measured", or the number that was counted.
An entry without evidence is a statement of intent, and this file is not for those.

Sections per release: **New** · **Changed** · **Fixed** · **Still missing**. The last one is the important one —
a gap that is written down is not a surprise.

---

## 0.57.98 (2026-10-19) — explainable diagnosis, end to end: update-domain, incident timeline, and the fleet picture

The diagnosis grew from one service on one host into a loop across the whole fleet, reachable the same way from a
person and from an AI (REST · MCP · the in-app chat · the console): a second domain (updates), a live incident
timeline, permalinks and a fleet-wide board, precedent ("seen before") and recurrence ("what keeps breaking"), the
remedy proposals filed against a diagnosis, CSV/GELF export, and — beyond diagnosis — authoring an OU/group config
policy over MCP and the changelog served in the UI. Plans: docs/diagnosis-plan.md, docs/update-diagnosis-plan.md,
docs/etw-ringbuffer-plan.md.

### New
- **The in-app chat assistant can read the fleet diagnosis picture** — besides `diagnose_service`, the chat dock now has `recent_diagnoses_fleet`, `recurring_failures` and `recent_incidents`, so asking "was bricht gerade ständig?" in the UI gets an answer (read-only; same surface as the MCP tools).
- **A diagnosis shows the remedy proposals filed for it** — traceability from a diagnosis to the governance action taken on it (was a fix proposed, approved or still pending). `GET /api/v1/diagnoses/{id}/proposals`; a line on the diagnosis panel links to the Change-proposals queue. (Bossman never runs a remedy itself, so this records a fix was decided, not that it ran.)
- **"What keeps breaking" — recurring failure modes across the fleet.** Stored diagnoses are grouped by failure mode
  (leading rule), most frequent first: count, distinct hosts, how many did not hold, last seen — so a fleet-wide cause
  stands out (high count *and* many hosts = fix it once). On the Diagnoses board as a "What keeps breaking" section you
  click to drill into a mode; `GET /api/v1/diagnoses/recurring` and the MCP tool `recurring_failures(within_days)`.
- **A diagnosis shows where the same failure was "seen before"** — its precedent across the fleet (the roadmap's
  RAG-cause lens, concretely). The panel lists other diagnoses with the same leading rule (same failure mode), elsewhere
  or earlier, each linking to its own permalink — the recurrence a root cause hides behind. `GET
  /api/v1/diagnoses/{id}/related`; the AI gets the same via `recent_diagnoses_fleet(q=<rule>)`. Read-only.
- **The AI can author a fleet-wide config policy over MCP** (`set_config_policy`), not only a single host. It converges
  a file toward a desired key→value map for a whole OU or host-group, like linking a GPO. Preview-first (dry-run shows
  the blast radius on every member, persists nothing); an apply is governance-gated the way `set_host_config` is —
  it proceeds only under YOLO mode, otherwise it is refused with the preview and points at the Policy console, where a
  human owns a fleet-wide change. The REST route's authoring logic was extracted into one shared `author_config_policy`
  so REST and MCP cannot drift (characterization tests written first as the net; MCP tests cover preview/refuse/scope).
- **A fleet-wide Diagnoses board** — stored diagnoses were only reachable host by host (the Services snap-in's "Past
  diagnoses"); now `/diagnoses` lists every host's diagnoses newest-first, each opening at its permalink, with contract
  violations flagged and filters for status / contract / free text (+ CSV export). `GET /api/v1/diagnoses` (admin, like
  the fleet-wide audit list) and the MCP tool `recent_diagnoses_fleet(status, contract_status, q)` so the AI can scan
  "what is wrong anywhere right now" and find documents that did not hold. Reached from the Fleet workspace and linked
  from the per-host history and the permalink page.
- **The changelog is reachable from the web UI, not only the README.** The Help page gains a "Changelog" tab that
  renders `CHANGELOG.md` (served by `GET /api/v1/help/changelog`, the same way the README backs the Documentation tab),
  so "what is new, what changed, what is still missing" is one click away in the app — the global rule that a project's
  changelog is linked from both the README and the web page.
- **Fleet boards export to CSV** (monitoring gap #5, the practical slice). The Fleet Overview, Software Compliance and
  Capacity-forecast and Security boards each have an "Export CSV" button that downloads their current table — compliance flattens
  every rule's per-host drift into one report, capacity writes the growth/ETA forecast, and Security exports the CVE findings (one row per CVE+host). The **Audit log** exports too,
  but **server-side** (`GET /api/v1/audit/export.csv`, same filters as the list) so the file is the whole matching
  trail, not just the page shown — what a compliance auditor needs; the filter is one shared query, so the export and
  the on-screen list can't disagree. One shared `shared/csv.ts` helper does the RFC-4180 serialising and the download
  (the Fleet Overview's own copy was folded into it), so there is one implementation, not one per board. PDF, scheduling
  and emailed SLA/inventory reports stay deferred. Playwright captures the Capacity and Audit downloads and checks they
  are real CSV.
- **Create a Windows patch ring from a form, with a dry-run check page** (peer UX concept #5). The Rollouts page gains
  a "New patch ring" form (install state, reboot, update categories, accept/reject KBs, scope, waves, dry-run on by
  default). Submitting plans it and shows a check page — how many Windows hosts were kept, the waves, and every host
  that was skipped *with the reason* (not a Windows host / no address) — before anything is started; the ring then lives
  in the rollouts list and installs nothing until Start. *Verified live:* a dry-run ring on bossman-wintest (1 host,
  canary wave) and a global dry-run (1 kept, 16 skipped with reasons); Playwright drives the form → check page → list.
- **Send a diagnosis to Graylog from the console, and see the GELF target in Settings** (peer UX concept #4). A
  diagnosis panel now has a "Send to Graylog" button that forwards its GELF messages (one per finding and per evidence,
  tagged with the diagnosis id) to the configured target and reports how many went over which transport — greyed up
  front with the reason when no target is set, not offered then refused. Settings gains a read-only "Graylog (GELF)
  target" card (new `GET /api/v1/system/graylog`) showing host/port/protocol (env-based, not secret) or that none is
  configured. *Verified live* (dev stack `BOSSMAN_GELF_HOST=graylog`): a send delivered 8 GELF messages to
  udp://graylog:12201; Playwright covers the Settings card and the send-from-permalink flow.
- **A saved diagnosis has its own link, and a host's past diagnoses are listable** (peer UX concept #3). A diagnosis
  kept by Bossman is now reachable at `/diagnoses/:id` — a permalink you can send to a colleague or paste into a ticket,
  shown read-only exactly as it was recorded (export / explain / propose still work on it; "diagnose again" does not,
  because a saved diagnosis is what was true then, not a live re-run). The management console's Services snap-in gains a
  "Past diagnoses…" action that lists a host's kept diagnoses newest-first (`GET /agents/:id/diagnoses`), each row a link
  to its permalink, with contract violations flagged — so "is this new or recurring?" is answerable before asking for a
  fresh diagnosis. The diagnosis panel learned a second, stored mode for this without changing its fresh-diagnose DOM.
  *Verified live:* `GET /diagnoses/:id` returns the full document; Playwright drives the list → permalink flow and a cold
  permalink load, and the existing fresh-diagnose panel test still passes.
- **A host's recent crashes and OOM kills, as a timeline you can pull** (peer UX concept #2). The incident ring the
  diagnosis already looks back on (an abnormal exit, a crash, a .NET exception, or on Linux an OOM kill / fatal signal —
  what a diagnosis cites as `svc.recent_incident`) is now a standalone, read-only tool so the UI and the AI can show the
  whole timeline for a host, not only the entries one diagnosis happened to touch. `recent_incidents(host, kind, image,
  within_minutes, limit)` (MCP) / `GET /api/v1/agents/{id}/incidents` ask the host's own ring live — **nothing is
  stored in Bossman**. Both agents answer under one contract: the Linux agent (Go) serves the eBPF collector's ring, the
  Windows agent (C#) serves the ETW ring, with a byte-identical output shape (newest first; each incident carries the
  same stable `evidence_id` a diagnosis cites). The honesty is in the envelope: every answer states `ring_state`
  (`available` | `not_supported:<reason>`), `capacity`, `persistent` and `since`, because the ring is bounded — an empty
  list after a restart is a named gap, **not** "nothing ever crashed" (on Windows the ring is persistent and survives a
  reboot; on Linux it is in-memory, so `since` is when the agent started capturing). A host whose agent is too old gets a
  named refusal ("no recent_incidents module — update the agent"), never a silent empty answer. **The Windows incident
  ring now records only FATAL exceptions**, not every handled throw: live verification found the ETW ring was 99.5%
  noise (199 of 200 entries were handled .NET exceptions from gpresult/SIHClient/PowerShell and the agent itself, which
  the CLR provider fires on for every throw), burying the one real process-exit. A .NET exception is kept only when its
  process then dies abnormally within the window — the exception that actually killed it; a handled exception whose
  process keeps running is discarded (new `IncidentCorrelator`, agent 0.3.32). *Verified live:* driving
  `windows_update_facts` (PowerShell-heavy, throws many handled exceptions) added **zero** new incidents. This also
  resolves the evidence_id collisions seen live (one exception per process death, one exit per pid → unique ids).
  Tests: Go module (no-ring
  → named `not_supported`, filters + newest-first sort); Bossman proxy (a live read is passed through with the host and
  keeps no row; a missing module is a named refusal); C# module (184 dotnet tests pass). Windows agent 0.3.31.
  *Verified live (2026-10-19, rebuilt bossman + bossman-ui + dev agent):* `GET /agents/{id}/incidents` returned **501**
  with the host name and agent version on an old Linux agent (pve1, 0.57.93) and an old Windows agent (bossman-wintest,
  0.3.30); on hal (agent carrying the module, eBPF off) it returned **200** with `ring_state: "not_supported: the eBPF
  collector is not running…"` — a named gap, not an empty "no crashes". Playwright drove the UI: the "Recent incidents…"
  action opens the timeline and shows that ring state plainly.
- **Patch rings and rollouts are fully drivable over MCP, and their state machine has no dead ends** (from the peer
  session's UX review). The AI can now run a rollout end to end: `start_rollout`, `rollout_status`, `abort_rollout`,
  `pause_rollout`, `resume_rollout` as MCP tools (they existed only as REST before, yet `create_patch_ring`'s own text
  told the model to "start it"). `create_patch_ring` gained the knobs the REST endpoint already had — `state`,
  `reject_list`, `ou` scope, `strategy` — by sharing one `plan_patch_ring` service between REST and MCP instead of a
  second, thinner copy. And the two states the model listed but never reached are now real: **pause/resume** (a rollout
  stops at the next wave boundary keeping its progress, and resume continues from that wave without re-applying the
  done ones — the driver is resumable), and **failed** (an unhandled error in the driver now lands the rollout as
  `failed` with a finish time, instead of leaving it stuck `running` forever). Tests: the executor marks a crashed
  rollout failed; 63 patch-ring/rollout/MCP/management tests pass.
- **A second diagnosis domain: updates.** The same explainable-diagnosis contract now answers "why is this host behind
  on updates, or why did an update fail?" — a new target kind `updates` alongside services. `diagnose_updates(host)`
  (MCP) / `POST /api/v1/agents/{id}/diagnose-updates` asks the host's own `update_diagnose` module and keeps the
  document: findings `upd.install_failed` (with the HRESULT in Windows' words), `upd.reboot_pending`,
  `upd.wsus_unreachable`, `upd.held`, `upd.dpkg_interrupted`, `upd.repo_unreachable`, `upd.behind`, `upd.up_to_date`,
  each with a certainty and cited evidence. Windows reads the Windows Update Agent (via the existing read-only
  `windows_update_facts`, no new measurement); Linux reads apt/dnf (`apt-get -s upgrade`, `apt-mark showhold`,
  `dpkg --audit`, `dnf list --upgrades`, `/run/reboot-required`). *Verified live:* on bossman-wintest (status behind,
  `upd.behind`) and in a Debian pod (`upd.reboot_pending` + `upd.held` + `upd.behind` from real apt data). (U0–U3 shipped
  in 0.57.97; the catalogue, both agents and the Bossman tool.)
- **An update fix proposes a snapshot as its rollback.** Installing updates is not reversible by itself, so the remedy's
  way back is a filesystem snapshot: on Linux the diagnosis detects (read-only) whether `/` is on LVM or ZFS and, only
  then, `upd.behind` carries a remedy whose `before` takes the snapshot (`lvcreate --snapshot` / `zfs snapshot`) and
  whose rollback restores it (`lvconvert --merge` + reboot / `zfs rollback`); the Ansible export emits the
  snapshot→install playbook and the restore playbook. When `/` is not on a snapshot-capable volume — and on Windows,
  which has no guest snapshot and where a KB uninstall only reverses uninstallable updates — **no remedy is offered**,
  only a named gap pointing at a patch ring / `windows_update` and, for a real rollback, a hypervisor/VM snapshot. The
  "every remedy has a rollback" contract stays honest. The remedy is a four-eyes proposal + exported playbook, never
  auto-run. Tests across all three languages; schema actions `install`/`restore` added.

---

## 0.57.97 (2026-10-18) — kernel tuning: what can this kernel be tuned with?

Plan and description: docs/kernel-tuning.md.

### New
- **Experiments decide whether a tunable helps** (block 5): `experiment_start/status/experiments` over MCP and REST.
  A/B runs alternate, each B is undone with the module's own undo, the host ends at A (checked). The verdict
  (better / worse / no_difference / inconclusive / aborted) rests on an exact Mann-Whitney U test plus a 2 %
  minimum effect. **Verified on Ubuntu 26.04:** scx_bpfland shortens hackbench by 6.6 % (p = 0.0015, 10+10 runs).
- **Rehearsal on a Proxmox VM** (block 6): `snapshot=true` snapshots the VM, runs the experiment (a reboot-needing
  tunable sequentially) and rolls the VM back.
- **scx is baked into the agent package** (`scripts/build-scx.sh`, `/usr/lib/yoloman/scx/<version>`), and
  `scx_install` links it in seconds. **Verified:** scx_bpfland attached on Fedora 44 and AlmaLinux 10.2 and was
  rolled back, through Bossman.
- **UI:** a blocked button stays focusable and names its reason (142 buttons, `npm run lint:disabled`); status
  pills with icon + word; a Ctrl/Cmd-K command palette; a table density switch.
- **`vm_delete(remove_host=true)`** and **`call_agent_tool(timeout_seconds=…)`** for everything over MCP.

- **`yoloman.scx_install` builds the scx schedulers from a pinned upstream release** (default v1.1.4), because no
  distribution ships scx that loads into its kernel. It builds as its own transient unit, with the states
  built / building / absent, a build log on failure, and a one-call rollback, and links `/usr/local/bin/scx_<name>`
  for `yoloman.sched_ext`. Verified on Ubuntu 26.04.1 through MCP: built in 4 min 03 s. **`scx_bpfland` then
  attached to kernel 7.0** through the tunable resource and was rolled back to the fair class. hackbench median
  4.308 s against 4.667 s with the fair class (3 runs a side, no overlap); cyclictest p99 unchanged. 4 tests.
- **A model installs a host end to end (probe):** qwen3.8-27b, given nine MCP tools, found a free address, read the
  ten pre-flight checks, deployed Fedora 44 (6 min 13 s), benchmarked, tuned readahead, benchmarked again and rolled
  back, in 13 rounds and 14 minutes without a failed step. It called its own +2.85 % IOPS result noise.
- **`deployment_status(wait_s=…)`** waits up to 600 s for the deployment to change instead of being polled in a
  loop, so a model spends one round per change, not one per second.
- **Every page in the navigation is crawled by Playwright** (`e2e/crawl.spec.ts`, the list is read from `app.ts`):
  console errors, page errors, API responses ≥ 400 and visible alerts, with a screenshot per page. 49 of 49 pages
  were clean against the merged tree.
- **Deploy a VM from the UI** (Deploy → Install hosts). The page lists every deployment with its install state,
  whether the agent has reported, and the finalization's outcome. The wizard walks through target, operating system
  (Fedora, AlmaLinux, Debian or Ubuntu, newest release resolved live, or a golden image), machine, network (free
  addresses suggested and checked against Bossman, NetBox and a live ping), and an optional finalization playbook,
  in check mode or applied. A disabled Next always shows its reason. Deploy unlocks only after the dry run's
  pre-flight checks all pass. The wizard and MCP `deploy_vm` run the same code. Verified with Playwright against the
  Proxmox cluster "PVE Lab": the page lists the real deployments (kt-alma-01, kt-debian-01, kt-ubuntu-01), and every
  wizard step's gate, the live release lookup, the IP suggestion and check, and the dry run passed (3 tests).

- **The agent states its kernel's tuning capabilities** (block 1, `internal/kernelcaps`). It reports BTF, the seven
  relevant `CONFIG_*` flags with the file they came from, the sched_ext state and the attached BPF scheduler, the
  boot loader and the init system. Each value is a named state with the file that proved it, and `unknown` names the
  path it could not read. The setup module exposes this as `yoloman_kernel_caps`, and the host inventory as
  `kernel_caps`. Verified on this workstation (kernel 7.0.0-38-generic): BTF present, all seven flags `y` from
  `/boot/config-7.0.0-38-generic`, sched_ext `disabled`, grub, systemd. 6 tests.

- **Run-queue latency, OOM kills and signals are stored as time series** (block 2): `runq_latency_us_bucket{le}`,
  `oom_kill_total` and `signal_total{signal}`, per collect interval. Before, they were only live lists, and nothing
  could compare the time before a change with the time after it. Cardinality is bounded (no PID labels). Verified
  on this workstation with the agent running as root: 13 run-queue buckets under load, `SIGKILL` = 3 after three
  kills, `oom_kill_total` = 1 in the interval of a provoked OOM kill (python3 in a 30 MB scope). 2 tests.

- **Five kernel tunables as agent modules** (block 3, baked into the agent): `yoloman.sched_ext` (a BPF CPU
  scheduler from the scx project, or back to the fair class), `yoloman.systemd_resource` (cgroup limits of a unit),
  `yoloman.blockdev_tuning` (readahead, I/O scheduler), `yoloman.cpu_governor`, `yoloman.kernel_cmdline` (grubby,
  GRUB, extlinux). All share one result shape: before/after, `live | persistent | pending_reboot`, the backend,
  and a rollback that restores the previous state in one call, persistence included. Refusals say why
  (`unsupported:`, `tool_unavailable:`, `conflict:`) and happen before anything is changed. Verified on this
  workstation as root: a loop device (readahead 2560 → 4096, none → mq-deadline, udev rule) and a transient
  unit (cgroup `cpu.weight` 100 → 400, `memory.high` max → 256M) were both restored exactly by their reported
  rollback. On a real Debian 13 VM, driven through Bossman's MCP (`call_agent_tool`): `sda` readahead and
  `cron.service` limits were restored exactly by their rollback, and `kernel_cmdline` went through the whole
  cycle — `transparent_hugepage=madvise` was pending, became live after a reboot (THP `[madvise]`), and was gone
  again after the rollback and a second reboot. `sched_ext` correctly refused there, because Debian's 6.12
  kernel has `CONFIG_SCHED_CLASS_EXT=n`. A real BPF scheduler attaching and a real governor change are not
  verified yet. 15 tests.

- **Kernel tunables are desired state** (block 4): the resource kind `tunable` (`sched_ext`, `cpu_governor`,
  `kernel_cmdline`, `systemd_resource:<unit>`, `blockdev_tuning:<device>`) has plan, apply, generations and rollback
  through the same MCP tools and REST routes as every other kind. Each generation keeps the module's undo, so
  `resource_rollback(generation=0)` restores the state before yoloman managed the tunable. Module refusals
  arrive as `action: refused` with their kind and reason. Verified through MCP on the Debian 13 VM
  test-deployment: `systemd_resource:cron.service` plan → apply (generation 1, CPUWeight 50, MemoryHigh 128M) →
  second apply records nothing → `rollback(0)` gives back `[not set]`/infinity without the drop-in; `sched_ext`
  is refused as `unsupported` with Debian's reason. Tests: 5, DB-backed through the MCP tools.

- **MCP tool `update_agent`**: updates a host's agent to the package Bossman ships, `dry_run` first (package,
  size, sha256, the version the host reports). It needs the same host grant as the REST route and says how to
  get one when it refuses. Verified through MCP: refused without a grant, the dry run on test-deployment, the
  push (the agent restarted 15:09:25), and still refused for a host the grant does not cover. 1 test.

- **VM deployment over MCP**: `vm_hosts`, `check_ip`, `suggest_free_ips`, `deploy_vm` (dry run first, with every
  pre-flight check) and `deployment_status`, built on the code the REST auto-provision route now shares
  (`services/vm_provision.py`). The IP check asks Bossman's records, NetBox (optional, new `BOSSMAN_NETBOX_*`
  settings) and a live ping plus ARP from an agent in the subnet. NetBox alone was wrong twice on 192.0.2.0/24.
  Verified through MCP against Proxmox "PVE Lab": placement, the IP verdicts, and a dry run of 192.0.2.134 on
  VLAN 1028. 2 tests.
- **`yoloman.benchmark`** (block 5): one run of a fixed profile per call — scheduler latency (cyclictest),
  scheduler throughput (hackbench), CPU (stress-ng), memory (sysbench), random read (fio) — with unit, direction,
  tool version and command. Each workload runs as its own transient systemd unit, because the agent unit's
  `RestrictRealtime=true` seccomp filter is inherited by children and made cyclictest fail. The unit is started
  `--no-block` and waited for, because `--wait` failed on systemd 259. Verified for all five profiles on Debian 13
  and on Fedora 44 (sched_latency p99 75 µs and 78 µs). 2 tests.
- **Every MCP tool that contacts a host or runs something on it checks the host ACL**, as REST does. Before, a
  token without any grant could run `command` and `reboot` through MCP. Reading Bossman's own records and
  monitoring writes stay open, as over REST. 1 test.

- **Fedora VMs through MCP**: `deploy_vm(install="fedora[-<release>]")` installs with Fedora's own network installer
  and a generated kickstart, including the agent with a pre-minted identity, scx-scheds and the benchmark tools.
  The job is done when the new agent reports. Verified on Proxmox "PVE Lab" (VLAN 1028, 192.0.2.134): DHCP only
  for the VM's MAC, pxelinux, the per-MAC entry, Fedora 44 kernel/initrd/stage2, and the kickstart fetched locally.
  5 tests.
- **The PXE DHCP answers only the MACs of armed jobs** (`restricted`). A job without a MAC opens it for 15 minutes
  (`open`), and otherwise it is `off`; the reason is logged. The same holds for the manual WebUI flow and MCP.
  4 tests.
- **MCP tools `set_netboot`, `vm_status` (with CPU/network/disk counters), `vm_power`, `vm_delete`** (only VMs
  Bossman created). Netboot and package availability are `deploy_vm` pre-flight checks: Fedora has no `scx-scheds`,
  and the missing package had stopped the installer at an interactive prompt.
- **`python -m bossman.tools.mcp_agent`**: a model drives Bossman through MCP with a tool subset and a JSONL step
  log. The console model is configured as `qwen3.8-27b` on llm.

### Changed
- **One install wizard instead of two.** Disk images → *New deployment* opens Deploy → **Install hosts** (renamed
  from "Virtual machines") on its image, and the old provisioning wizard is gone. The one wizard and `deploy_vm`
  now cover what only the old one could: bare metal by MAC, a golden image's volume sizing (now for this
  deployment only; the old wizard wrote it into the image, so every later deployment inherited it), the
  bootstrap→production VLAN handoff, roles, and saved templates. Unlike the old one, it runs every pre-flight check
  (address, packages, memory, roles, sizing) before anything is created. **Roles are now really bound:**
  `deploy_vm(roles=[…])` used to store the names and never bind them.
- **Volume sizing per volume, not per role.** debian13-tmpl has three volumes of role `data` (/opt, /tmp, /usr) that
  shared one value, and the page summed it three times ("Sum: 80 % — must be 100"). The page's "must be 100" also
  contradicted the API, where the last volume takes the rest. Keys are now mountpoints (a role key still applies to
  every volume of that role), and one shared editor follows the backend's rules.
- **`update-bundled` no longer sends a .deb to a host of unknown OS family.** It used to send "everything else"
  the .deb, so a host enrolled seconds ago, or an RPM host with unusual facts, was sent a package its installer
  cannot read. It is now refused with the reason. REST and MCP share `services/agent_update.py`.
- **MCP reaches every resource kind.** `resource_observe/plan/apply/generations/rollback` built resources
  through their own list (docker, helm, config, role), so `package`, `service` and `k8s` existed over REST but
  not over MCP. They now use the registry, the one construction path, and `k8s` takes its cluster, namespace,
  api_version and object_kind there too.
- **One OS-family table** for the setup fact `ansible_os_family` and the Starlark `ctx.facts()["os_family"]`
  (`internal/osfamily`). The Starlark side used to ignore `ID_LIKE` and did not know SUSE, Arch or Alpine (it
  returned `opensuse-tumbleweed` or `sles`), so a module and a runbook could disagree about a host.
- **A failed eBPF collector load is now a fact, not just a log line.** `ebpf_collector` is `loaded`, `failed`
  (with the kernel's error), `disabled` (with the config switch) or `not_started`.

### Fixed
- **dnsmasq runs only while a deployment job is armed, and never as a DNS server.** It ran all the time: with no
  job it served TFTP on port 69 and an open recursive DNS resolver on the lab segment's address (port 53;
  measured: it resolved example.org for anyone). Now no job means no dnsmasq (ports 67/69 free); an armed job
  starts it with `port=0` and hands out `PXE_DNS_SERVER` as the DNS server. Verified with a dummy job: listening
  on 67, 4011 and 69 only while armed, stopped after the cancel.
- **Public RPMs no longer carry the build machine's hostname.** nfpm writes it into the RPM header (`BUILDHOST`);
  every public RPM since 0.57.70 carried it. The 0.57.97 RPMs were rebuilt in a UTS namespace named
  `build.example.internal` (the first upload was replaced), and both package scripts now always do so. The
  Bossman RPM is xz-compressed: with gzip it was 100.06 MB, over GitHub's file limit for the package repository.
- **The release carries its manifest again** (`yoloman-agent-<version>.manifest.json`): with 0.57.73 Bossman saw
  the release but no checksums (`sha256: ""`). Verified: the running Bossman reports 0.57.97 with both checksums.
- **A preview no longer predicts an install that would fail**: apt/dnf/yum/dnf5 check mode asks the repositories,
  so a package nobody ships fails the dry run (measured: Ubuntu's non-existent "scx" was "changed: true").
- **MCP no longer drops an unknown argument silently**: every tool refuses it and names the closest declared one
  (`arguments` → `params`), and the schemas say `additionalProperties: false`.
- **The timeout message names the timeout that applied** (it always said 30 s) and the parameter it recommends
  now exists.
- **The PXE HTTP root is a volume** (`pxe-http`): pe.squashfs and the installers' mirror survive a recreation.
- **The Deploy page offered a cluster as a target**; it is shown with the reason (select its member hosts).
- **Test residue removed**: 8 test agents, the last blueprint runbook, finished test VMs.
- **PXE**: dnsmasq listened on a DOWN bridge (`br-ens19`) and never saw a DHCP request; it now takes the UP interface
  that carries the listen IP. `build-pe.sh` broke on a PE root with two kernels; it now takes the newest.
- **A test no longer switches the live netboot off**: `test_images_api.py` restores the shared settings row.
- **Three parallel installs ran the PXE DHCP dry.** The range had two addresses; the third VM got "no address
  available". Each network-install MAC now gets the static address its deployment was checked for
  (`dhcp-host=<mac>,<ip>`). Verified: the waiting Ubuntu VM got 192.0.2.137 on its next DHCP try and booted the installer.
- **AlmaLinux 10 never came up**: Proxmox gave the VM `kvm64`, and Alma 10 needs x86-64-v3. Measured: 285 MB
  fetched, then 50 minutes with zero bytes written. The driver now sets `x86-64-v3`; the same install took 3 min
  22 s to the agent's first report.
- **Ubuntu stalled with 6 GB**: its initramfs loads the 2.93 GB ISO into a tmpfs of half the RAM, and wget stopped
  at 2.29 GB twice (nginx log). Minimum memory is 8192 MB; with it the ISO arrived whole and the disk filled.
- **A deleted VM no longer shows as "done"**: `vm_delete` sets the deployment to `vm_deleted` (the reason names
  the previous state) and cancels a finalization still waiting for it.
- **A test stamped every real host as seen**: `test_poll_once_only_polls_enrolled_agents` polled all enrolled
  agents of the shared database with a fake client (version `0.0.0-test`); a waiting Ubuntu install was marked done
  and lost its seed. `poll_once(only=…)` scopes it to the test's own agents.

### Still missing
- `cpu_governor` has not changed a real governor: every test VM so far exposes no cpufreq driver. systemd-boot
  and UKI hosts are `unsupported` in `kernel_cmdline`, and OpenRC in `systemd_resource`.
- The bundled scx binaries are glibc builds; a musl host (Alpine) would need its own.
- `docker-compose.override.yml` sets `PXE_INTERFACE=br-ens19` (down) and lacks `PXE_LISTEN_IP`; the entrypoint
  corrects the interface, but the listen IP must be set.
- Block 7, the tuning loop (proposal → rehearsal → guarded apply → regression watch), is open; blocks 5 and 6 are
  done. SUSE, Arch and Alpine have no network installer yet (prepared: docs/netinstall-more-distros.md; Alpine
  first needs a musl agent).

---

## 0.57.97 (2026-10-18) — explainable diagnosis: why does a service not start?

Plan: docs/diagnosis-plan.md · description: docs/diagnosis.md.

### New
- **A diagnosis can explain a PAST incident, not just the present state** (ETW ring buffer E0/E1/E3, 2026-10-18).
  Until now the diagnosis read the current state — a service that crashed at 03:00 and restarted looked fine by the
  time anyone asked. The Windows agent now keeps a bounded, in-memory **incident ring** filled by a persistent
  real-time **ETW session**: an abnormal process exit (with its code), an image crash (an NTSTATUS failure), and a
  managed **.NET exception** (by type) — metadata only, no payloads, no memory, no dump, so it is privacy-safe by
  construction, and clean exits are dropped so an always-on session stays cheap. `service_diagnose` reads the ring for
  the service's image and adds a `svc.recent_incident` finding (**Likely** — it describes a past invocation, never the
  present, so the certainty is never raised) that cites each incident as evidence. *Verified live on bossman-wintest:*
  a service running `ProbeService --mode=crash` produced a diagnosis with **both** `svc.crash` (Proven, from the SCM
  events) and `svc.recent_incident` (Likely) citing two real ring entries — the `System.InvalidOperationException` the
  CLR provider caught and the process crash (exit 0xE0434352) the kernel provider caught. The rule is in the catalogue
  on both platforms (order 950, ranked after every present cause). The ring **survives a reboot**: it is flushed to a
  small, size-capped file in the agent's state dir on every clean stop (and once a minute as a backstop) and reloaded
  at startup — *verified live* by crashing a service, restarting the agent, and seeing the diagnosis still report the
  incident the new ETW session never witnessed. **Linux has the same thing**, reusing what the agent's eBPF collector
  already records — OOM kills and fatal signals (SEGV/ABRT/KILL/QUIT; a normal TERM/INT stop is not an incident): the
  systemd diagnosis reads them for the unit's process and adds the same `svc.recent_incident` finding. It is
  **read-only on the metrics store** — the incidents live in the collector's in-memory ring and surface only on demand
  in a diagnosis document, adding no Timescale series. *Verified live on a real kernel:* a SIGSEGV'd process was caught
  by the collector and came back as a diagnosis incident. The UI timeline is the remaining step. 29 C# ring/mapping
  tests + rules tests on both platforms, catalogue consistent in all three languages. Plan: docs/etw-ringbuffer-plan.md.
- **One contract for "why does it not work", shared by both agents and Bossman** (block B0): evidence (one
  measurement, stable id, source, time, a readable fact, the raw data), findings (rule, claim, certainty
  Proven/Likely/Unknown, cited evidence, the preceding change, a remedy as data), timeline and named gaps —
  `configs/schemas/diagnosis.schema.json`. The rule catalogue `configs/diagnosis_rules.json` gives one name per cause on
  both platforms (a missing executable is `svc.image_missing` for Windows' error 2 and systemd's 203/EXEC) and the
  highest certainty each rule may give. Four golden documents (Windows logon right, Windows dependency, Linux
  203/EXEC, an Unknown with its gap) and the one document check `services/diagnosis_contract.py`: a finding without
  evidence, a cited evidence that does not exist, an Unknown without its gap, a stopped service without any finding,
  a certainty above the rule's maximum, a precedent passed off as the cause — each named, never repaired. 18 tests.
- **The Linux agent's diagnosis core** (B1, `internal/diagnosis`): the contract as Go types, a builder that refuses a
  forbidden finding the moment a rule tries it (no evidence, unknown evidence, Unknown without gap, certainty above
  the rule, precedent as cause, a remedy the rule does not offer, a rule of another platform), findings ordered by the
  catalogue, timeline and summary derived. The catalogue is embedded (kept identical to configs/ by a test). The four
  golden documents round-trip through the Go model without losing a field and pass the JSON schema in Go too; a
  counter-test shows the Go validator refuses what it should.
- **Linux: `service_diagnose` explains why a systemd unit does not run** (B2). It reads `systemctl show` (Result,
  ExecMainStatus, LoadState …), the Requires/BindsTo chain recursively, the unit's account, its program and the journal
  of the CURRENT invocation, and applies the rules: unit missing, masked, 203/EXEC (Proven when the program is absent,
  Likely when it exists), 217/USER, credential/state directories, the deepest failed required unit, timeout, crash,
  OOM kill, start limit, unmet conditions, the program's own exit code, and the causes the package e2e classifier read
  from journal text (now in the agent, Likely, citing the matching lines). A cleanly stopped or finished oneshot unit
  is `svc.stopped_cleanly`; nothing matching is `svc.unexplained` with what was read. Verified on this workstation:
  `fwupd-refresh.service` → svc.exits_immediately (exit code 1, Proven), `anacron.service` → svc.stopped_cleanly,
  `ssh.service` → running. Found on the way: an unprivileged reader gets NO journal lines and rc 0 — now a named gap
  instead of silence. 16 rule/collector tests, each document checked against the schema.
- **Verified on a real systemd, both families** (B3, `tools/diagnosis_probe_linux.py`): 13 units broken in one known
  way each (missing program, missing account, failed dependency, masked, own exit code, SIGSEGV, timeout, start limit,
  missing credential, unmet condition, no such unit, clean oneshot, running) in fresh Debian trixie and AlmaLinux 9
  systemd pods — **26 of 26** diagnosed with the expected rule and certainty, every document within the contract
  (agent 0.57.89, results `configs/diagnosis_probe_linux.json`). The probes corrected three rules that the snapshot
  tests had right only on paper: systemd 257 keeps `Result=exit-code` when the start limit refuses a restart and says
  so only in its own journal message; a unit that never ran reports `ConditionResult=no` without a timestamp (it was
  read as an unmet condition); a skipped unit is garbage-collected and only systemd's journal message tells why.
- **The Windows agent's diagnosis core** (B4, `windows-agent/AgenticMcp.Agent.Diagnosis`, net10.0 so it is tested on
  Linux): the contract as C# types, the embedded catalogue (byte-identical to configs/, by test), the builder and the
  validator — the same refusals as Go and Python. The four golden documents round-trip through the C# model without
  losing a field; 20 new C# tests, 98 in all.
- **Windows: `service_diagnose` explains why a service does not start — verified on the real host** (B5, agent
  0.3.1 on bossman-wintest, Server 2022, German locale). It reads the service control manager (QueryServiceConfig,
  QueryServiceStatusEx, the dependency chain with load-order groups via EnumServicesStatusEx) and the System and
  Application event logs by event id and EventData — never the localized message text — and names: no such service,
  disabled, image missing, unquoted image path, account missing, logon failed, the missing log-on-as-a-service right,
  the deepest failed dependency, timeout, crash (with the application error), the service's own exit code, stopped
  cleanly, or Unknown with its gap. `tools/diagnosis_probe_windows.py` breaks 9 services on purpose through the
  agent (sc.exe) and checks each diagnosis: **9 of 9** with the expected rule and certainty, every document within
  the contract (`configs/diagnosis_probe_windows.json`). The host corrected two rules: after a failed start the SCM
  reports Win32ExitCode 0 again, so the newest event 7000 carries the last attempt's error; and Server 2022 records
  the missing logon right as event 7041, not as 7038 with error 1385.
- **Windows: the account behind a service and its access to the program** (B6, agent 0.3.2). `service_diagnose` now
  reads the account itself instead of waiting for a failed start: whether the name resolves to a SID (virtual,
  managed, local or domain account), for a local account whether it is disabled, locked out or has an expired
  password (NetUserGetInfo), its log-on-as-a-service right — granted directly or through which group, and any deny
  right (LsaEnumerateAccountRights) — and whether it may execute the image and traverse its folder
  (AuthzAccessCheck, naming the denying ACE). New evidence `lsa:account:`, `lsa:rights:<sid>`,
  `authz:<sid>:<path>`; a missing right is now Proven before anyone starts the service, a disabled account Likely
  before a start and Proven after the failed logon; access denied comes with an ACL remedy; what could not be read
  (a virtual account has no SAM entry, a domain account without the DC) is a named gap. Probe on bossman-wintest:
  **13 of 13** (4 new: right missing read from LSA without a start, disabled account, deleted account, an explicit
  deny ACE on the image), each citing its own measurement. 5 new C# tests, 123 in all.
- **What changed before it broke — the precedent, on both platforms** (B7; Linux agent 0.57.90, Windows agent 0.3.3).
  Every finding now names the most recent change before the failure, with the seconds in between: on Linux the unit
  file, a drop-in or the program (by inode change time — dpkg/rpm keep the package's mtime, measured: `/usr/bin/ls`
  mtime is the build date, its ctime the second dpkg.log records the upgrade) and the owning package's last change
  from dpkg.log or rpm; on Windows the service key's LastWriteTime (and its dependencies'), the image's creation/write
  time, events 7045/7040. A change of the service wins over a newer change of the host; the host's newest install or
  update (dpkg.log / rpm; MsiInstaller, Windows Update — without Defender's daily definitions) is named only when the
  service itself did not change. Window 7 days; every change is on the timeline either way; still a correlation,
  never a cause. Probes: Linux **28 of 28** (Debian + AlmaLinux; new: `chmod -x` on the program after the unit was
  written — the later change is the one named), Windows **14 of 14** (new: created, then disabled 3 s later — the
  precedent is event 7040, not the creation). 8 new Go tests, 5 new C# tests (128).
- **Bossman keeps the diagnoses and lets you ask for one** (B8). `POST /api/v1/agents/{id}/diagnose` asks the host,
  checks the document again against the contract and stores it (table `diagnoses`, one row per run, the document
  unchanged); `GET /api/v1/agents/{id}/diagnoses` is the host's history, `GET /api/v1/diagnoses/{id}` one document.
  For a language model: the MCP tools `diagnose_service` / `recent_diagnoses` and the chat tool `diagnose_service`,
  whose descriptions say how to use a diagnosis honestly (repeat the certainty, cite evidence ids, a precedent is a
  correlation, propose a remedy instead of applying it). A document that does not hold is stored as
  `contract_status: violation` with its reasons and never repaired; an agent without the module answers with a named
  refusal. *Verified live:* bossman-wintest's `wuauserv` stored (`svc.stopped_cleanly`, Proven, with a Windows-update
  precedent marked as a host change); pve1 (agent 0.57.42) → 501 "has no service_diagnose module — update the
  agent". 5 DB-backed tests (a Windows and a Linux golden through the same path, a violation kept as sent, the
  refusal, an answer without a document).
- **A diagnosis in the formats other tools read — and its repairs tried on the real host** (B9).
  `GET /api/v1/diagnoses/{id}/export/{format}` and the MCP tool `export_diagnosis`: `checkmk` (a `<<<local>>>` line,
  the cause as its text; Unknown and a document that does not hold are Checkmk's UNKNOWN), `gelf` (one message per
  finding and per evidence, `_correlation_id` = the diagnosis), `ansible` (FQCN modules, an apply and a rollback
  playbook — both pass ansible-lint, checked in the tests), `dsc` (DSC v3, only the native
  `Microsoft.Windows/Service` — available since DSC 3.2), `powershell` (apply + rollback to read and run). What a
  format cannot express is listed in `not_expressible` with the reason, never left out. *Verified on bossman-wintest*
  (`diagnosis_probe_windows --repair`): the PowerShell export applied for a disabled service, a missing logon right
  (seen in the event log, and read from LSA) and a deny ACE on the program — a new diagnosis no longer reports the
  rule, the rollback brings it back, 4 of 4; the full probe 14 of 14 on agent 0.3.4.
- **A repair is proposed, approved by a second person — and never run by Bossman** (B10). `POST
  /api/v1/diagnoses/{id}/propose` (MCP `propose_remedy`) files one finding's remedy as a change proposal: the claim
  and certainty, the evidence it rests on, before/after, rollback, how it is verified, and the Ansible/DSC/PowerShell
  artifacts for that finding. The proposer sees "Approve (does not run it)" greyed with the four-eyes reason before
  clicking (`can_approve` / `cannot_approve_reason` per caller in the proposal API); a second person's approval is
  recorded with the artifacts attached and `executed: false`. A finding without a remedy or a diagnosis that does not
  hold is refused with the reason. *Verified:* Playwright against bossman-wintest — a service created disabled,
  diagnosed `svc.disabled` Proven, proposed by one admin (greyed for them), approved by another, and a new diagnosis
  still finds it disabled; 5 DB-backed tests (one asserts that approving never builds an agent client); the
  consistency crawler stays at 57 of 57.
- **An explanation that cannot claim more than the evidence** (B11). `GET /api/v1/diagnoses/{id}/explain` gives a
  code-written header — each finding's certainty and claim, its precedent, its remedy and every gap, word for word —
  and sentences from the model (structured `{text, evidence_ids}`, thinking off, no token cap) or a template. Each
  sentence is checked: `backed: false` with the reason when it cites nothing, cites an id that is not in the
  diagnosis, states a certainty itself ("sicher", "probably" …), or names a name, number, code or time that the cited
  evidence does not contain (a "1053" against a 1069 is caught). The MCP tool `check_explanation` runs the same check
  on an explanation a calling AI wrote. *Verified:* 7 tests with prepared model answers + 1 MCP test; live on
  Bossman the template path for a bossman-wintest diagnosis, 0 unbacked. The check caught the first template itself
  (it stated computed seconds that no evidence holds) — the template now names the measured time.
- **"Why is it not running?" in the management console, for Windows services and systemd units** (B12). A row
  action in the Services snap-in opens the diagnosis: summary, each finding with its certainty badge, the evidence
  behind it on demand, the preceding change labelled a correlation, what could not be observed, the timeline, the
  repair with its undo and how it is verified, the exports, "Propose this repair", and "Explain" with every sentence
  the evidence does not back marked *not backed* with the reason. On an agent without the module the action is
  greyed with that reason before anyone clicks (the console now does this for any row action whose module the host
  does not publish). *Verified with Playwright:* bossman-wintest (a service created disabled → `svc.disabled`
  Proven, evidence, explanation with 0 unbacked, PowerShell export, proposal filed), this workstation's
  `fwupd-refresh.service` (failed → `svc.exits_immediately` Proven; its precedent a python3-urllib3 upgrade, shown as a
  host change, and the unprivileged agent's missing journal access shown as a gap), pve1 (agent 0.57.42 → greyed
  with the reason); the consistency crawler stays at 57 of 57.
- **What Windows Update says about a host** (B13 step 1, Windows agent 0.3.5): the read-only module
  `windows_update_facts` — pending updates (KB, title, categories, MsrcSeverity, reboot behaviour, downloaded, size),
  the last 50 history entries with Windows' own result codes and HRESULT, last successful search and install, the
  update server (Windows Update, or the WSUS a policy assigns) and a pending reboot. A value Windows leaves empty is a
  named state (`unrated`), and updates without CVE ids are counted in `cve_gap` with the reason. *Measured on
  bossman-wintest:* 4 pending (malicious-software removal tool, the .NET cumulative update "Important", the Defender
  definitions, the September OS cumulative update), 50 history entries, and **none of the four carries a CVE id** —
  so the CVE list (step 2) will come from Microsoft's published security data, not from the host. Interpretation
  tested on the recorded answer (5 tests). Also: `service_diagnose` and `windows_update_facts` are now listed with a
  reason on a non-Windows build, like the other Windows modules (`service_diagnose` was missing there).
- **Windows hosts in the security view, with their CVEs** (B13 step 2). The CVE feed now also reads Microsoft's
  security update guide (MSRC CVRF, the last 6 monthly documents) into a KB → CVE index with MSRC's own severity
  words, and the fleet sweep reads a Windows host through `windows_update_facts`: each pending update's CVEs come
  from the host when Windows names them, otherwise from that index; an update with no known CVE is logged by KB, not
  dropped. Before this a Windows host had no `package_updates` module and fell out of the sweep without a word.
  The security view ranks and counts "Critical" (MSRC) and "critical" (RHEL) as one word. *Verified live:* a feed
  refresh read 24 150 KB→CVE pairs; bossman-wintest shows **645 CVEs (61 Critical, 584 Important)**, all closed by
  the pending September cumulative update KB5122882 — a sample of the mapping is Windows Server 2022 components
  only; the .NET rollup KB5128928 has no CVE in Microsoft's data. 6 new tests (MSRC parsing with the real document
  shape, correlation, refresh + cache, the Windows sweep, the fleet ranking — the security endpoints had no test).
- **The Windows agent installs updates** (B13 step 3, agent 0.3.6): `windows_update` searches, downloads and
  installs through the Windows Update Agent with the parameters of `ansible.windows.win_updates` (category_names,
  accept_list within the categories, reject_list, reboot never|if_required — default never), dry_run lists what would
  be taken, and every pending update ends up selected or skipped with its reason. Each result is Windows' own
  (Succeeded … Aborted + HRESULT); an update is `installed` only when a NEW read confirms it (history Succeeded, no
  longer pending) — otherwise `unverified` with the reason — and a needed reboot is the outcome `reboot_required`, not
  success. The security view's bulk update now installs, on a Windows host, the KBs that close its CVEs. *Verified
  on bossman-wintest:* the Defender definition update KB2267602 installed and verified in 22 s; the .NET cumulative
  update KB5128928 installed → `reboot_required`, the host was NOT restarted and reports the pending reboot; the bulk
  update's dry run selects exactly KB5122882 (the KB behind the 645 CVEs). 9 tests (selection over the recorded
  answer — including "an accept_list applies within the categories", as in Ansible — and the result verification).
  The module reference pages (docs/modules-windows.md, docs/modules-linux.md) are regenerated from the live agents.
- **The Linux Ansible remedy export is proven against a real host** (B9, 2026-10-18). Until now the apply/rollback
  playbooks a diagnosis produces were only checked as YAML and by ansible-lint. `tools/ansible_remedy_probe_linux.py`
  now breaks a systemd unit, diagnoses it with the agent, exports the remedy and runs BOTH playbooks against a real
  systemd pod through the `kubernetes.core.kubectl` connection (no SSH — the modules run inside the pod), then checks
  the observable host state flips and reverts. Two cases, two different FQCN modules: `ansible.builtin.user` (the
  missing account goes absent → present → absent, by `getent`) and `ansible.builtin.systemd_service` (a masked unit
  goes masked → not-masked → masked). Both rc=0, changed, nothing in `not_expressible`. One honest caveat recorded:
  creating the account does not by itself clear `svc.account_missing`, because `systemctl show` reports the unit's last
  failed run until it is restarted — so the proof is the observable state, not the re-diagnosis (for `masked` the
  re-diagnosis does flip, `svc.disabled` → `svc.stopped_cleanly` → `svc.disabled`).
- **A diagnosis can be sent to Graylog** (B9, 2026-10-18). The GELF export was produced before but never left Bossman;
  now `POST /api/v1/diagnoses/{id}/export/gelf/send` puts those messages on the wire — UDP (chunked to the GELF spec
  when a message is too big for one datagram) or TCP (NUL-terminated frames), `services/gelf_send.py`. Sending stays
  **off** until `BOSSMAN_GELF_HOST` is set: the export is always there for inspection, and the send endpoint then
  refuses with the reason (422), a connection error is a 502 with the reason — never a silent drop. Each message is
  tagged with the diagnosis id (`_correlation_id`), its kind, and a finding's rule and certainty, so one diagnosis is
  one correlated group. The dev stack now ships a throwaway Graylog under the `graylog` compose profile (Graylog + its
  mandatory MongoDB + OpenSearch; `docker compose --profile graylog up -d`, UI on 127.0.0.1:9000). *Verified:* a real
  `windows-logon-right` diagnosis sent over UDP arrived as 6 messages (1 finding `svc.logon_right_missing` Proven +
  5 evidence), every field intact, confirmed through Graylog's own search API by correlation id — and the GELF
  timestamp is the measurement time, not the send time (an old finding lands under its own date). 6 tests (the sender's
  UDP/chunking/TCP framing and the endpoint's gating, over a real socket). **Still missing:** the Ansible export is
  still only linted, not run against a host.
- **Patch rings: Windows updates roll out in waves with a health gate** (B13, 2026-10-18). A patch ring is not a new
  mechanism — it is an ordinary staged rollout (the same machinery as role deployments) whose per-wave action is the
  `windows_update` module, so canary → ring 1 → ring 2, the health gate between rings, pause/abort, dry-run and the
  Rollouts UI all carry over, and a KB never lands on the whole fleet at once. `POST /api/v1/patch-rings` (and the MCP
  tool `create_patch_ring`) take a scope (host, group or global), keep only the Windows hosts — every non-Windows host
  in the scope comes back in `skipped` with its reason, nothing drops silently — plan the waves and create a rollout in
  `status=pending`: **nothing installs until the rollout is started**, and `dry_run` defaults to on. The runbook has one
  `windows_update` step reused by signature; `reboot` defaults to `never` so a wave never drops the agent mid-step.
  *Verified on bossman-wintest* (dry run, host scope, accept KB2267602): the ring built one canary wave over the single
  Windows host, the started rollout finished `done`, the wave reported "0/1 newly CRIT (0% vs gate 0%)" healthy, and
  nothing was installed. 4 tests. **Still missing:** only one Windows host in the dev fleet, so multi-ring progression
  could not be demonstrated end to end.
- **The explanation runs on the local model** (B11, decided 2026-10-17: local llama.cpp, not OpenRouter — the
  diagnosis data stays in-house). `BOSSMAN_CHAT_BASE_URL` / `BOSSMAN_CHAT_MODEL` are passed through docker-compose
  from the gitignored `.env`; only on-demand features use it, nothing in the background. *Verified live:* a
  bossman-wintest diagnosis explained in German in 14 s, 4 of 4 sentences backed; this workstation's fwupd-refresh
  in 7 s, where the check flagged "Remediation-Verfahren" — a false positive (a German compound read as a name),
  fixed: a hyphenated compound of capitalised words is prose, a lowercase or digit-carrying one is a name (test).
- **A Windows cumulative update installed through the security view, and its CVE rows gone** (B13, the last
  criterion; decided 2026-10-17: install + reboot). The first attempt ended `Failed 0x8024200D` — the agent now
  names it (0.3.7: `WU_E_UH_NEEDANOTHERDOWNLOAD: the update has to be downloaded again`, plus ten other documented
  Windows Update HRESULTs; an unlisted code stays its number). After the pending .NET reboot the bulk update
  installed KB5122882 in 742 s → `reboot_required` (not restarted by the module) → restart → history `Succeeded`,
  no longer pending, and after the next collection **all 645 CVE rows of that KB are gone**. Windows then offers the
  October cumulative update KB5126655, whose 977 CVEs now show — the view follows the host, it does not declare it
  clean.
- **The Linux diagnosis checked against the package e2e's own classifier — and corrected** (B3 cross-check, agent
  0.57.91). The 39 roles whose service did not run in the package e2e were installed with their shipped configuration
  on fresh pods and diagnosed by the agent: **33 agree**, 2 where the agent is more specific (a failed dependency where
  the classifier saw no journal), 2 reviewed disagreements (svxlink's reason is only in its own log file; comitup is a
  missing D-Bus service, not hardware), 2 without a diagnosis because the role locks the agent out (ferm is a
  firewall, connman reconfigures the network). Found and fixed on the way: the agent's journal rules had been ported
  only partly (13 cases: "needs to be enabled", "No such file or directory", "cmap key", coretemp/hdaps …), and a unit
  in `activating (auto-restart)` — failing and waiting to be restarted — was read as "starting" with no finding (3
  cases). Linux probe still 28 of 28.
- **Windows: a real exit code, a real crash and a real hang** (B5 remainder, Windows agent 0.3.9). A small test
  service (`AgenticMcp.Agent.ProbeService`, built by the probe and fetched by the host itself, not part of the
  package) fails on purpose: `--mode=exit-specific:42` → `svc.exits_immediately` Proven, `crash` → `svc.crash` Proven,
  `hang` → `svc.timeout` **Likely** — measured that a start which never ends stays START_PENDING with no event at
  all, so the agent now reads how long it has been pending past the SCM's 30 s timeout without progress (before it
  said "starting" and nothing else). Windows probe **17 of 17**, the 4 repairs included. The Windows rollout tool
  refuses to redeploy a version the host already runs (a second build under one number misled its own wait).
- **"Software updates" in the console for Windows too** (B13). One snap-in for both families: Linux keeps the package
  manager's list, Windows gets "Windows Update — pending" (KB, title, MsrcSeverity, reboot behaviour; "Install this
  update", "Install updates…" with the preview first) and "Update history" (Windows' result words, HRESULT); the node a
  host cannot serve says why. New snap-in requirement `any_of`. *Verified with Playwright* on bossman-wintest
  (KB5126655 pending with its install action; KB5122882 `Succeeded` in the history).
- **The diagnosis found why the long-lived test hosts had no agent** (Linux agent 0.57.92). Since the workstation's
  reboot two days earlier, the agents on all five package-e2e test hosts were down. Asked through `service_diagnose`:
  `yoloman-agent.service` → `svc.dependency_failed` Proven (it requires `e2e-register.service`, failed); that unit →
  exit code 1, journal "dial tcp 192.168.49.1:8123: connect: connection refused" — the pods' enrollment ran before
  Bossman was up. Fixed in the test image (the enrollment retries until Bossman answers) and on the five hosts
  (restarted, all reachable again). The same case showed one more rule gap: Go's lowercase "connection refused" did
  not match the peer pattern — now case-insensitive (test with the real line).
- **The way back: uninstalling an update** (B13, Windows agent 0.3.11). `windows_update` with `state: removed` takes
  only explicitly named KBs (`accept_list`), runs `wusa /uninstall /quiet /norestart`, maps wusa's exit codes to
  outcomes (0 removed, 3010 `reboot_required`, 0x00240007 not installed, others failed with the number) and counts an
  update as removed only when a fresh read no longer lists it. Refused with the reason instead of tried: what Windows
  Update marks as not uninstallable (the combined servicing stack + cumulative update needs DISM), and an update only
  Windows Update knows — measured: the installed .NET rollup KB5128928 is not in Get-HotFix (it lands as per-product
  updates), so the first version called it "not installed", which was false. *Verified on bossman-wintest as a dry
  run* (KB5128928 refused with that reason, KB5122882 would go to wusa, an unknown KB not installed); a real removal
  has not been run on the test host.
- **An RPM upgrade no longer leaves the agent stopped and disabled** (agent package 0.57.93). Found while updating
  the fleet: on the RHEL test hosts the new package started the agent, then the OLD package's `%postun` ran — rpm
  runs it after the new `%post` — and stopped and disabled it. The postremove script now acts only on a real removal
  (deb `remove`/`purge`, rpm `0`), and the rpm package carries a `posttrans` that enables and restarts the agent at the
  very end, which also repairs an upgrade FROM a package that still has the old script. *Verified:* e2e-rh-1 and
  e2e-rh-2 upgraded 0.57.92 → 0.57.93 through `update-bundled` — active and enabled afterwards (0.57.76 → 0.57.92 had
  left both down). Debian was not affected: dpkg runs the old postrm before the new postinst.
- **The Linux fleet runs the diagnosis** (2026-10-18, agent 0.57.93, through Bossman's own `update-bundled`). In
  waves: the test host test-deployment (0.57.49 — the closest to production's age: the old configuration starts),
  the five e2e test hosts, then the Proxmox production nodes pve1 (pilot), pve2, pve3 one after another
  (0.57.42). Checked per production node: pveproxy/pvedaemon/pve-cluster/corosync `active` before and after,
  `service_diagnose` answers through Bossman, Bossman records the new version and metrics flow on the next poll.
  Found on the way: the rpm upgrade defect (above). Not updated: hal (the workstation's dev agent, run by hand),
  bossman-poller (a container, updated with the compose build), the unreachable `0.0.0-test` stubs.
- **Windows: the rollback tried for real, and the October update installed** (decided 2026-10-17). `windows_update
  state=removed` on KB5122882 ran wusa, which exited **87** (`ERROR_INVALID_PARAMETER`) — the module reported
  `failed` with that code and the update stayed installed (history). That is how wusa answers for a combined
  servicing stack + cumulative update; only DISM removes those. The October cumulative update KB5126655 was then
  installed through the bulk update (`reboot_required` → restart) and the security view shows **0** open CVEs for
  bossman-wintest after the next collection (977 before).
- **Windows' own reason for a failed service logon — a wrong password is now provable** (Windows agent 0.3.15). The
  agent reads the Security log's 4625 (logon type 5, by services.exe, for the service's account) that belongs to the
  last start attempt and cites its NTSTATUS: `SubStatus 0xC000006A` the password stored for the service is wrong (no
  other source could prove that), `0xC0000072` disabled, `0xC000015B` the right is missing, and more. A 4625 from an
  earlier attempt is not claimed for the last one; a host that does not audit failed logons is a named gap (the
  audit policy is read by GUID, not by auditpol's localized names). *Verified on bossman-wintest* (auditing "success
  and failure"): wrong password, disabled account and missing right each cite their 4625. Found on the way: Windows
  hands NTSTATUS over SIGNED ("-1073741718") — 0.3.14 parsed only the unsigned form and never matched; the tests had
  guessed the format, now they use the measured one.
- **A deadlock in a service is proven, not guessed** (B14 step 1, Windows agent 0.3.14). For a start or stop that is
  pending the agent reads every thread's wait chain through Wait Chain Traversal — no memory dump, nothing of the
  process's memory leaves it — and a chain Windows reports as a cycle is the new finding `svc.deadlock` Proven:
  "thread 5904 → Mutex …\yoloman-probe-b (Owned) → thread 1488 → Mutex …\yoloman-probe-a → back to the first".
  *Verified* with the probe service's new `--mode=deadlock` on bossman-wintest. Measured limit: a .NET program waiting
  through `Mutex.WaitOne` is invisible to the chain (its threads show Blocked on nothing) — the probe uses native
  mutexes, and such a hang stays `svc.timeout` Likely. Windows probe **19 of 19**, 4 repairs.
- **A Windows host no longer looks clean right after a reboot** (Windows agent 0.3.14 + Bossman). Measured during the
  rollback test: 19 s after a reboot Windows Update answered `SucceededWithErrors` with an empty list, three minutes
  later `Succeeded` with two updates — and the security view had briefly shown 0 CVEs. The agent now marks a search
  that did not succeed as `complete: false` with the reason, and Bossman keeps the host's last complete CVE state.
- **The rollback through DISM, tried for real** (B13): KB5126655 removed by its package (DISM 3010, package gone) →
  restart → no longer installed, offered again with its 977 CVEs; reinstalled through the bulk update → restart → 0.
- **Where a Windows service crashed — the function, from public symbols, without a memory dump** (B14 step 2a, Windows
  agent 0.3.18). The crash finding now names the faulting function: module and offset from the application error,
  the module's own PDB key from its PE header, the PDB from Microsoft's symbol server (fetched by the host into a cache
  — nothing of the crashed process leaves it) and Windows' own dbghelp to name the symbol; for .NET services also the
  exception and first managed frame from event 1026. *Verified on bossman-wintest:* ".NET exception (0xE0434352) in
  KERNELBASE!RaiseException+0x6C; unhandled System.InvalidOperationException: … at ProbeService.<>c.<OnStart>b__6_0()".
  Measured on the way: the FileVersion text of a Windows binary is stale (KERNELBASE read 10.0.20348.5622, its numeric
  version 20348.5756) — versions are compared by build and revision; a module updated since the crash is a named gap.
- **Fixed: unrelated events in every Windows diagnosis.** The Application log was read by event id only, so the
  performance-counter provider's 1000/1001 and every other program's crash of the last 24 h became evidence (40–92 per
  diagnosis). Now by provider, and only events that name the service's image — the running EventLog service went from
  46 evidences to 7. Windows probe 19 of 19, 4 repairs.
- **Fixed: the Windows rollout tool filled the test host's disk.** It kept every staged version (package + unpacked copy,
  19 of them, 3.9 GB) until C: had 0 bytes left and the next download failed mid-transfer. It now removes earlier stages
  before downloading; the host has 3.9 GB free again.
- **The explanation check understands two more spellings** (B14). Live on the local model for a crash and a deadlock:
  "0xE0434352" in prose was flagged although the event holds "e0434352" — hex values are now compared without `0x`;
  "30-Sekunden-Timeout" was flagged although the finding's own (code-written) claim states the SCM's 30 s — words of a
  claim that cites the same evidence count, and in a German compound only its number is the specific claim. What stays
  flagged is real: a sentence citing the configuration for an exception that is in the .NET event, and a sentence
  citing nothing. 1 new test.
- **Linux: a start that does not end shows where it waits** (B14, agent 0.57.94). A unit activating for more than 30 s
  is now `svc.timeout` Likely instead of "starting", with each thread's state and kernel wait channel from `/proc`
  as evidence — no debugger, no memory read. *Verified* in the Debian and AlmaLinux pods: "probe-hang.service hangs
  while starting: it has been activating for 35 s and its threads wait in the kernel in hrtimer_nanosleep". Linux
  probe 30 of 30. Not yet: where a Linux service crashed (no coredumps in this environment — see Still missing).
- **Linux: where a service crashed, by function, without a core dump** (B14, agent 0.57.96; user chose kernel line +
  debuginfod). The crash finding now names the faulting function: the kernel logs every user-space fault with the
  module and instruction pointer, the agent maps that into the module's ELF and resolves the symbol — a local debug
  file, else debuginfod by build id, else the module's own or (named as such) exported symbols. *Proven on a real
  pod* with a static crasher: "probe-nativecrash.service crashed: segfault at 0x10 in yoloman-crasher!crashy", evidence
  `ksym:yoloman-crasher:...` ("faulted at yoloman-crasher!crashy+0x17 … the module's own symbol table"). Measured on
  the way: the newer kernel format is `module[<offset>,base+size]` with a "likely on CPU" tail — the parser handles
  both. Linux probe 30 of 30. The address→function resolution is also unit-tested against a freshly compiled ELF.
- **A managed .NET hang is named, not left blank** (B14 step 2b, Windows agent 0.3.20). When a hung service's wait
  chain shows blocked threads but no lock owner and the process is .NET — detected by its `dotnet-diagnostic-<pid>`
  pipe, because a single-file self-contained app loads coreclr from memory and never as a listed module (measured) —
  the finding carries a gap saying Wait Chain Traversal cannot follow a managed wait (Mutex.WaitOne / Monitor) and a
  managed stack dump would be needed. *Verified on bossman-wintest:* the probe's `hang` (a managed sleep) now gets
  that gap, while `deadlock` (native mutexes) stays `svc.deadlock` Proven with none. A real managed-stack capture
  (dotnet-stack / ClrMD) is left as a later step — the value beyond naming the limit is narrow.
- **A service blocked by application-control policy is named, with the image's signature** (new rule
  `svc.blocked_by_policy`, Windows agent 0.3.26). When AppLocker (event 8004) or Windows Defender Application Control /
  Code Integrity (event 3077) blocked the service's program from running, that is the finding — Proven, citing the block
  event. Every Windows diagnosis now also carries the image's Authenticode trust as evidence (WinVerifyTrust), and
  crucially **including the security catalog**: Windows system binaries carry no embedded signature and are catalog-
  signed, so an embedded-only check called them all "unsigned" — fixed, cmd.exe now reads "signed and trusted
  (CN=Microsoft Windows…)". A state that could not be confirmed is reported honestly as "no embedded signature (not
  confirmed against the security catalog)", never falsely as "not signed". *Verified:* the signature live on
  cmd.exe/ProbeService; the block rule via recorded events (enforcing AppLocker on the host would change its security
  policy). Windows probe 19 of 19; 5 tests for the rule and signature.
- **The Windows agent can be updated in place from here** (`tools/deploy_windows_agent.py` +
  `packaging/update-agent.ps1`): publish, the agent fetches the build itself and a one-shot SYSTEM task runs the
  update with the installed configuration (token, port, write gate kept). Found on the way: the host's corporate
  proxy answered 503 for a LAN address, and the agent's PowerShell host cannot load the Archive or ScheduledTasks
  modules under the machine's execution policy — both worked around and named in the tool.
- Two transitive CVE pins raised/added so the Windows agent builds at all: System.Security.Cryptography.Xml
  10.0.11 → 10.0.13 (GHSA-r955-8q5j-3h83) and System.Security.Cryptography.Pkcs 9.0.10 → 10.0.13
  (GHSA-846f-f764-76mx, GHSA-2fmv-rv2c-59x7).

### Fixed
- **A logon right granted after a failed start was still reported as the cause** (Windows agent 0.3.4): the event
  7041 recorded at the failed start kept `svc.logon_right_missing` firing although LSA measured the right as held.
  The current measurement now beats history; the finding says the recorded cause no longer holds and a new start
  will tell. Found by applying the exported repair on bossman-wintest.
- **`GET /api/v1/diagnoses/{id}` answered 422** (B8): it used the per-host ACL dependency that reads the agent id
  from the path, which this route does not have. The ACL is now checked against the diagnosis's own host; a REST
  test drives ask → list → read → export through the app and a caller without a grant gets 403.
- **The Windows agent reported an old version to Bossman**: the host project carried both `<Version>` and a
  separate `<AssemblyVersion>`, and `/healthz` reads the latter — a 0.3.2 binary answered "0.3.1" (measured
  2026-10-17 on bossman-wintest). One number now; `/healthz` and Bossman show 0.3.2.

### Still missing
- **What the explanation check cannot catch:** a sentence that predicts or concludes without naming anything
  specific ("…, wodurch der Dienst erfolgreich gestartet werden kann" — seen on the first live run) passes, because
  the check reads names, numbers, codes, times and certainty words, not meaning.
- The Windows Ansible export is linted, not yet run against a host (needs WinRM to the test host). The Linux Ansible
  export is now run for real against a systemd pod (apply + rollback through the kubectl connection).
- Not read yet: the Windows image signature (WinVerifyTrust), Reliability-monitor records as Windows changes, dnf
  history (the rpm install time stands in). A diagnosis of a service that is not a Windows service or systemd unit
  (a container, a cron job) does not exist.
- **Installing Windows patches — what is still open:** a real uninstall on the test host (needs approval); multi-ring
  progression could not be shown end to end (only one Windows host in the dev fleet).
- **B14:** done — deadlocks (wait chains), crash locations from symbols (Windows + Linux), hang thread states
  (Linux /proc), and managed hangs named as WCT's limit. A real managed-stack capture (ClrMD) is a possible later step.

## 0.57.97 (2026-10-18) — package-config e2e: what is still missing

Named, so none of it is a surprise (plan: docs/package-config-e2e-plan.md):
- **Templates that still change their file with defaults.** Each reachable one has its reason recorded
  (configs/template_differs_reasons.json): most would lose operator fields if rebuilt from the shipped file (531
  units), or the file's format cannot be fielded by the builder (XML, JSON, block configs: 291). Deciding per role
  between the model's extra fields and the shipped layout is open.
- **"pass-unverified" is most of the queue's output** (662 of 737 pods on tick 3): configured and re-read, but no
  verified checker exists for the package. Wrong content in such a template is caught only by stage 5 — the
  `wrong-file` rule catches a template of another file, not a wrong value in the right one. 90 Debian and 219
  RedHat packages are still unrouted.
- **Roles that need a design, not a fix:** krb5-kdc (realm + KDC master password), swift rings (binary, built by
  swift-ring-builder), chasquid (a directory named after the domain), certificates and keys (by reference from the
  password store, not as deployment parameters).
- **Container limits, not product gaps:** auditd, iscsi-target, resolvconf-dependent packages and init-system
  replacements cannot run in the test pods; auditd's restart fix is covered by tests only.
- **Config files the maintainer script creates are invisible to the routes**: Debian's zabbix-agent, -server and
  -proxy packages ship their real config (/etc/zabbix/zabbix_agentd.conf …) under /usr/share and copy it into /etc
  in postinst, so the archive's Contents index lists only the init script and a logrotate fragment — and the route
  went to /etc/logrotate.d/zabbix-agent (found 2026-10-17 when zabbix_agentd -T was probed against that fragment).
  Following postinst/ucf copies is not built yet.
- **287 packages have no route** (90 Debian, 197 RedHat — on RedHat mostly fonts and fontpath entries): each is
  recorded `unrouted` with the reason, none is "pending". The LLM queue is through (2026-10-17): qualify 0 pending
  for both families, the checker miner 0 pending.
- **Few packages have a verified checker.** Every mined check command on a routed package was probed on a fresh
  test host: Debian 81 verified / 331 rejected, RedHat 62 verified / 202 rejected (~20 % of the model's proposals
  hold). 414 + 190 packages have only a daemon command (not probed), 1129 + 1412 none at all — for them a
  configured file is `pass-unverified` at best.

## 0.57.97 (2026-10-18) — package-config e2e: the queue's output tested (F2 tick 3)

### Fixed
- **16 catalog roles wrote a different file than the one they name** — counted compliant, because nothing
  compared the content with the file: ppp's /etc/ppp/options got a logrotate rule, strongswan-charon's charon.conf
  an AppArmor profile, kresd.conf (Lua) a YAML list, buildbot `[default]` indices its init script never reads,
  opensc an `[opensc]` section instead of `app default { }`; also crm.conf, ferm.conf, fprintd.conf, inetsim.conf,
  insserv.conf, lircd.conf, mailto, mptcpd.conf, perdition, perlbal, snapserver. Rebuilt from the shipped file
  (`template_from_shipped`): all 16 render it **identically** with their defaults (stage 5), and fprintd, kresd,
  lircd the RPM's file too. Pod run: 15 pass-unverified, insserv install-failed (as before: an init system in a
  container); role path: kresd.conf, mptcpd.conf, snapserver compliant; ferm's shipped file fails in a container
  too (baseline shipped-fails). insserv and mailto ship nothing a field can name — they are install-only now,
  instead of writing a file of invented settings.
- **Six template/catalog defects found by package checkers** — dictd (`port:` outside its section), carbon-c-relay
  (a cluster without its type at defaults), kea-dhcp6 (SQL and reclaim keys in the memfile lease map; loggers
  outside Dhcp6 with the default `"["`), kea-dhcp-ddns (loggers outside DhcpDdns), cubemap (`error_log_type`, a
  parameter of `error_log`, in the directive catalog). All pass in the pod with the package's checker; the four
  kea units (Debian + new `-redhat` family templates, the RPM logs to a file) render the shipped settings.
- **tinyproxy** had tinyproxy.conf directives written into the shell environment file /etc/default/tinyproxy;
  rebuilt over the shipped file (same settings). swift-bench's `use_proxy` renders yes/no, not True/False.

- **The RedHat unrouted packages were never queued** — the qualify supervisor ran the worklist pass for Debian only
  and went straight to the checker miner; it now loops over every family (verified: the service ran
  `--family redhat --from-worklist`, [1/218] onwards).
- **A directory was routed as a config file**: chkconfig and initscripts pointed at /etc/init.d, and the pod failed
  with "is a directory". The e2e worklist applies the template index's directory rule; both are now no-config
  ("ships only a directory").

- **Packages the repository replaces were routed to files no host gets**: `dnf install hirte` installs
  bluechi-controller (Obsoletes: hirte < 0.6.0). Measured over all 1902 RedHat packages (`tools/rpm_replacements`):
  3 are replaced; the worklist routes them `replaced`, naming the package really installed.
- **A package's new route was never tested**: the e2e runner skipped a package with any earlier result, also of an
  older route — 29 packages; now a result counts only for its own route. The 29 ran: 22 pass-unverified,
  4 no-config-confirmed, 3 install-failed (container/site limits: resolvconf, Debian Edu, sympa's database).

- **Housekeeping's orphan-series sweep failed while the poller wrote a new series** (FK violation, seen after a
  restart): it now skips series with an insert in flight, like the process prune (two-session test, fails without
  the fix).

- **The checker miner erased probe decisions**: it loaded package_validators.json once and wrote its whole copy back
  after every package, and it re-mined rejected entries — 69 probe verdicts (verified/rejected) became unverified
  guesses again, and the F2 commit carried the damage. Both writers now reload and change one entry under a file
  lock (`validators_store`); the miner never touches an entry a test host has judged. The 69 are restored from
  7f68aaa66 (Debian 184, RedHat 21 decided entries again); tests for lost updates and concurrent writers.
- **Packages without a route stood as "pending" forever**: the e2e runner wrote the `unrouted` row only for a
  package that once had another route; 283 never-routed packages looked unfinished. Every package of both families
  now has a result or a named reason — the e2e table has no `pending` left (plan item F2 done).
- **A "checker" that never exits was filed as an infrastructure error**: the probe ran mined checkers until
  kubectl gave up, and 11 commands that start the service (`bearerbox`, `kresd -n`, `tlshd`, `i3status`) stayed
  open as infra-error. They now run under `timeout 60` in the pod; still running = rejected with that reason
  (11 rejected). Debian checkers now: 48 verified, 148 rejected, 170 with a daemon command only (not probed).
- **The qualify queue sent no request to the LLM for minutes**: man7.org hung behind the proxy (no answer in 40 s,
  manpages.debian.org 0.2 s), and every man-page candidate waited out its 20 s timeout there first — one package
  took 199 s just to be skipped. A mirror that does not answer is now skipped for the rest of the run (named once
  in the log); measured after the restart: 10–18 s per package (test).

### Changed
- **Key material is never a template target**: the index refuses bindings on keys, certificates and CA bundles
  (.der, .pem, .asc, trusted.gpg.d — 8 bindings, e.g. a template over elrepo's Secure Boot key), with the reason.
- **A binding that renders another file is withdrawn from the template index** (verdict `wrong-file`), measured:
  stage 5 renders it and not one setting it writes occurs in the shipped file (which has settings, and is the file
  AT that path). 145 bindings so far (85 Debian, 60 RedHat) — `config.ini` of one application on every config.ini,
  the `mdadm` template on a logcheck fragment, ssh_config in /etc/default/ssh. Catalog bindings are never withdrawn
  this way (they are fixed, see above). The reason is kept while the template is unchanged, so the index does not
  bind it again; a freed path is measured on the next tick (74 → 82 → 85 Debian over three rounds).
- **Package checkers count only when verified.** The miner wrote 850 Debian checkers nobody had run; 52 pod
  "failures" were the checkers'. Runners now use an entry only when its source says "verified", and
  `probe_checkers --mined` probed the mined ones: 20 verified, 134 rejected with the reason, 11 infra-error. The
  side-effect watch now covers /var/spool, /srv, /opt, /root (apt-mirror's "check" ran the mirror).
- **The qualify batch leaves curated templates alone** — catalog templates and meta `hand`/`repaired`; its Debian
  worklist pass had regenerated 17 repaired templates.

## 0.57.97 (2026-10-18) — package-config e2e: regressions of the 0.57.83 re-run

### Fixed

**The process-metric prune no longer aborts when the poller writes at the same moment.** It deleted a series it had
judged empty while the poller was adding a point to it, and failed on the foreign key — measured twice in 40 minutes.
A series being written is now skipped and pruned on a later run. *Test:* two sessions, a point in flight; fails
without the fix.

**Deleting a host that has just gone away no longer fails with a 500.** The delete cleared the host's service state
history, but the monitoring poller could commit one more state change in between (the services turn CRIT on the very
poll that finds the host gone), and the agent's own delete then hit the foreign key. The delete now locks the host's
row first, so a late state change waits and then fails on the missing host. *Measured:* every kept e2e test host's
cleanup returned 500 ("violates foreign key constraint service_state_history_agent_id_fkey"), and 36 agents of deleted
test pods had piled up in Bossman unnoticed; after the fix all 36 deleted with 204. A test holds the lock in one session
and shows a concurrent insert waits (it fails without the lock). The e2e runner now records a failed cleanup in the
result row (`cleanup_failed`) instead of ignoring the status.

**Roles can take a whole file as a site value.** Some daemons need a second file only the site can write — ctdb its
node list, the MySQL exporter its credentials. A role now declares such files; the wizard shows a multi-line field
(masked for secrets) and the role writes the file after its configuration. *Measured:* ctdb (never compliant before:
"unmet condition ConditionFileNotEmpty=/etc/ctdb/nodes") and prometheus-mysqld-exporter are compliant with test values.

**Kea DHCPv4 is a real role.** It only installed the metapackage before. It now configures the DHCPv4 server on
both families — the subnets (required: a value only the site has), interfaces and lease timers as fields, the rest of
the shipped kea-dhcp4.conf untouched — and restarts kea-dhcp4-server / kea-dhcp4. *Measured:* defaults reproduce the
shipped file exactly on Debian and AlmaLinux; compliant on both with a test subnet; `kea-dhcp4 -t` (verified against
the shipped file first) accepts the written configuration.

**rsyslog, MySQL and OpenDKIM configure AlmaLinux hosts.** The rsyslog and mysql-server roles only installed on EL;
they now write /etc/rsyslog.conf and /etc/my.cnf.d/mysql-server.cnf from templates built from the RPMs' own files and
restart rsyslog / mysqld. OpenDKIM no longer fails on a host without a domain name (the package's keygen skips such
hosts); the role creates the signing key itself. *Measured:* all three compliant on AlmaLinux.

**A config file of a newer package release keeps its codec (agent 0.57.85).** The codec registry records paths of the
release it was measured on — java-latest's `java-25-openjdk` while the mirror ships 27, java-21 paths with the full
package version — so every update left those files without a codec. The lookup now matches the same path of another
release when that names exactly one codec. *Test:* a versioned registry entry found under a newer version.

**Services that refuse a manual restart are restarted the way their package provides (next agent build).** auditd
refuses `systemctl restart` on every host (RefuseManualStop); a role changing auditd.conf could not apply it. The agent
now uses the package's own restart action and otherwise says why the restart was refused. *Test only:* auditd cannot
run in the test containers.

**Six more roles configure AlmaLinux's own file with the role's field names.** freeradius, bind9, vsftpd, proftpd,
cups and redis now render an EL template built from the RPM's file whose directives carry the role's field names —
freeradius shared none of its 34 fields with its EL template before, bind9 none. *Measured:* each reproduces the RPM's
file (five byte for byte, bind9 the same settings); all six roles compliant on AlmaLinux; bind9, cups and proftpd
pass their own checker.

**Postfix on AlmaLinux keeps its own main.cf.** The role rendered Debian's main.cf on EL hosts, dropping 32 settings
the RPM ships (its directory layout among them). It now renders `postfix-redhat`, built mechanically from the RPM's
file with the role's field names for the directives both files have (hostname, domain, relayhost, mynetworks,
inet_interfaces). *Measured:* defaults reproduce the RPM's main.cf byte for byte; the role is compliant on AlmaLinux
and `postfix check` accepts the written file. The builder (`template_from_shipped --names-from`) is generic.

**Applying a role with nothing changed now leaves more hosts as the package shipped them.** A template rendered with
its own defaults should reproduce the file the package ships; measured over every reachable template, about half of
the Debian catalog roles' templates did not (commented examples switched on, defaults that were the model's guess,
lines glued together). The mechanical repair chain — which nothing had been calling — now runs against the shipped
file and keeps a repair only when the result is closer to it for EVERY file the template renders, the sample still
renders, and (for catalog roles) the role still works when run for real. *Measured:* Debian catalog roles reproducing
the shipped settings 191 → 210 of 436 (45 catalog templates improved), AlmaLinux catalog 20 → 28 of 41; 62 further
index templates improved; no service role that was compliant got worse.
*Correction:* an earlier version of this entry reported 73 catalog repairs. That pass used a fuzzy "closest shipped
line" restore and an escape step that broke files while looking closer to the shipped text (containerd's config.toml
got duplicated TOML tables; postfix a comment switched on as a setting); all of it was reverted and redone with the
safe chain, which yields the numbers above.

**On an AlmaLinux host the wizard offers the fields of the file it will write.** A role's form was its Debian
template's fields; on AlmaLinux the role renders the family's own template, so fields it lacks were greyed out — and
9 of 26 such roles shared no field with it at all (bind9, clamav, exim4, freeradius, …). The form is now the union:
each family template's own fields join, marked with their family; the wizard greys out what the host's family file
does not have, with the reason, and the engine refuses a value set for such a field on the wrong family instead of
dropping it. *Measured:* bind9 gains 15 EL fields, haproxy 20, clamav 4; the roles stay compliant on both families;
the wizard tests pass on both.

**24 package checkers verified against the files the packages ship.** A checker (`nginx -t`, `named-checkconf`,
`postfix check`, `sshd -t`, …) is now trusted by the e2e suite only after it accepted the shipped file on a fresh test
host of that family; rejected ones are recorded with the reason (miredo-checkconf needs DNS; keepalived's shipped EL
example fails its own checker). *Measured:* 24 verified, 2 rejected, 3 without a shipped file; the 23 roles that gained
a checker are compliant on the Bossman path and their written files pass it. Roles with a verified checker: Debian 28
(was 15), AlmaLinux 20 (was 9).

**Templates no longer write `key = value` for a dictionary setting.** 121 templates looped `for k, v in X | dict2items`,
which the agent's engine renders as the literal words `key = value` for every entry — a role's postfix main.cf
contained that line, and containerd's config.toml carried `KEY = "value"` with its defaults. All 121 are rewritten
(`| dictsort`) and checked by rendering before and after; the template contract now refuses the construct and the
generating pipeline repairs it. *Measured:* none broke, 20 sample renders and 10 default renders now write the real
settings; the containerd checker accepts the role's file.

**A Debian host is no longer offered an AlmaLinux template.** The Debian template index bound 297 `-redhat`
templates (the RPM's file) to paths both distributions use; they are withdrawn from it, with the reason. *Measured:*
297 → 0.

**HAProxy is configurable on AlmaLinux.** The role's form is built from its Debian template, and the AlmaLinux file
is rendered by `haproxy-redhat` — whose fields had other names, so the wizard on an EL host greyed out all 19 of them.
`haproxy-redhat` now names the directives both files have like the role does (maxconn, user, group, mode, log, the
timeouts, the bind port, the backend, balance, the server pool and the TLS block), with the RPM's own values as
defaults. *Measured:* rendered with its defaults it reproduces the RPM's haproxy.cfg byte for byte; the role is
compliant on both families; the full Playwright run's only failure (this wizard on e2e-rh-1) passes.

**Configure no longer offers a role's template for a file that only shares its name.** The template index bound by
codec name: the crontab template was offered for /etc/pam.d/cron and /etc/default/cron, the haproxy.cfg template for
/etc/sysconfig/haproxy and /etc/logrotate.d/haproxy, redis.conf's for /etc/raddb/mods-available/redis — Configure
writes the whole file. The catalog now counts as a record of which file its role template renders, so such a binding
is refused with the reason; the same file in another location is still offered. *Measured:* 23 such bindings in the
recorded index, 0 after; tests per family against the real catalogs.

**Full UI run (Playwright).** 124 passed, 1 failed (the HAProxy wizard on AlmaLinux, fixed above), 5 skipped, each with
its named precondition; 20.9 min against the live backend and the e2e hosts.

**A package install that could not fetch its file is retried once (agent 0.57.84).** dnf, dnf5 and yum installs that
fail because a package file named by the metadata could not be fetched now drop the cached metadata and try once more —
what an operator does by hand. Any other failure is reported as before, and a second failure says the refresh was
tried. *Measured:* sshd on AlmaLinux had failed with "No such file … /var/cache/dnf/…/openssh-9.9p1-12…rpm"; on the
rebuilt images it was compliant twice. The failure did not reproduce on a real host, so the retry is covered by unit
tests only. The e2e images also refresh their baked package index once per build day.

**`man_search` verified on both families (agent 0.57.84).** Over Bossman's MCP endpoint, on a fresh Debian 13 host
(1370 pages) and a fresh AlmaLinux 9 host (338 pages): a search for "ssh daemon" finds sshd(8) and sshd_config(5), a
full-text search finds PermitRootLogin, and reading sshd_config(5) with grep PasswordAuthentication returns its
definition first. Next agent build: `pages_installed` is always the host's count (it was the count of the requested
section, so one host reported 1370 and 135), and the filtered count is `pages_in_section`.

**gnunet's role stays compliant.** The shipped unit wraps `gnunet-arm -s` as `Type=forking` without a PIDFile; systemd
guessed the main process, often found none, and about one restart in five ended "Deactivated successfully" with every
gnunet process gone. The role now runs ARM itself in the foreground (`Type=simple`). *Measured on a kept host:* 1 of 5
restarts dead before, 20 of 20 active after; compliant in 3 Bossman runs in a row (31.7 s, 29.1 s, 30.7 s).

**bip's role is compliant.** bip.service is `Type=forking` without a `PIDFile`, so systemd guessed the main process and
reported "Unit process … (bip) remains running after unit stopped" on restart. The catalog role adds a drop-in with
`PIDFile=/var/lib/bip/bip.pid` when the unit has none. *Measured:* compliant in 3 Bossman runs in a row (21.9 s,
16.2 s, 16.3 s), and 3 restarts on the kept host left the unit active.

## 0.57.97 (2026-10-18) — manual pages as a tool for the model

**An LLM can look things up in the host's own manual pages.** For an agentic OS the man pages are the best reference
there is: they document exactly the versions that run on the host, so even a small model can find which option,
directive or file does what instead of guessing from training data written for another release. The agent has a new
read-only module and MCP tool, `manpage`: search page names and summaries (`query`, like apropos) or inside the pages
(`full_text`, for an option name), then read a page as plain text narrowed to a `heading` (OPTIONS, FILES, EXAMPLES)
or a `grep` word — the paragraph that defines the word comes first, and example blocks keep their lines. It renders
man(7) and mdoc(7) natively, so it works without man-db or groff; a host without pages says so instead of returning
nothing. Bossman forwards it as `man_search(host, …)` on its MCP server and in the assistant, and its operator guide
points a model there before it changes a setting it is unsure about. *Measured: on this machine (8400 pages) a name
search takes 2.8 s and a full-text search about 5 s; over Bossman's MCP endpoint on a fresh Debian 13 host (1370 pages)
`man_search` found sshd_config(5) for "ssh daemon" and returned PasswordAuthentication's definition first.* (agent
0.57.83)

## 0.57.97 (2026-10-18) — defects the package / Kubernetes / host scenarios pinned, fixed

Worked 2026-10-09. Every product defect the Playwright scenarios had pinned with `test.fail()` in
`e2e/{packages,kubernetes,hosts,plan-run}.spec.ts` is fixed and its pin removed, so each scenario must now pass
for real. Agent 0.57.76. *Verified:* full suite `npx playwright test` 132 passed / 4 skipped (9.2 min) on the
recreated e2e hosts — the skips are preconditions, not pins: two parameterised consistency routes with no object to
open, and "the greyed-out Apply rollback says why" on both families because the rollback had changes to apply.

### Fixed

**A rollback reverts the whole host's managed config, as the UI says.** A generation is now the host's managed
configuration after one apply: it records the before-image of every file it changed, and rolling back to #N
restores every file a later generation changed (deleting files a later generation created); a rollback is itself a
generation. It used to re-apply only #N's own file — rolling back past a redis.conf edit read "No changes".
The generation table names the files each generation changed; a generation recorded before before-images existed
makes the rollback refuse with that reason instead of half-reverting. *Verified:* `go test ./internal/state`
(cross-file, delete, refuse cases); packages (d) on e2e-deb-1: the preview lists `/etc/redis/redis.conf`.

**RedHat hosts show their package config files.** Config discovery followed only *enabled* units and man pages;
RPM packages never enable their daemon and EL images ship no man pages, so `/etc/redis/redis.conf` and
`haproxy.cfg` were missing on AlmaLinux. Discovery now also reads the package database's declared config files of
every installed unit (`rpm -qcf`, dpkg conffiles). *Verified:* packages (d) on e2e-rh-1 (redis.conf by value, new
generation). (`/etc/fstab` stays absent there: the AlmaLinux container image has none.)

**A removed Debian package is no longer "installed".** `package_facts` counted dpkg `rc` entries (removed, config
files left); the console, Roles & Features and Resources → Packages now agree with `dpkg -l`. *Verified:*
packages (c) + cleanup on e2e-deb-1.

**Read-only hosts say so.** The agent publishes its write gate (`GET /api/v1/tools` → `write`, `withheld` with the
reason); the console greys write actions out up front with that reason, and a refused call is relayed as 403 with
the agent's sentence instead of 502 / "module missing or older than this console". *Verified:* packages
e2e-deb-ro (2 scenarios), `go test ./internal/server`, `test_management_api.py`.

**memcached renders memcached.conf.** The role bound the `/etc/default/memcached` template to
`/etc/memcached.conf`; the memcached.conf template was rewritten after memcached(1) (the old one emitted `-f
1048576`, `-S 48`), a RedHat template for `/etc/sysconfig/memcached` was added, and both templates record their
target so the template index refuses the wrong pairing. Install runbooks now always render the catalog's template
(install-chrony rendered the DAEMON_OPTS wrapper over chrony.conf the same way). *Verified:* packages "memcached";
`test_template_index.py`, `test_wizard_seed_catalog_masks.py`.

**Every role parameter starts on one of its own options** (apache2 `keepalive: On` was a YAML boolean). Checked
for every seeded role by a test; enums on list fields (hostapd `macaddr_acl`) are dropped.

**Kubernetes:** deferred objects show as "not validated yet" instead of a green create; the namespace cache is
refreshed when Bossman creates/deletes a namespace and re-read when a form names an unknown one; the inspector can
be closed (the Event Console button moved to the bottom-right, the drawer is above the table header); the YAML
tab's Apply/Preview name their reason and opening another object cancels the previous one's requests. A deletion
now passes the same approval gate as apply/scale, and a namespace delete preview lists what it still contains.
*Verified:* kubernetes 16/16, `test_resource_k8s.py`.

**Host page / plan run / roles:** `?tab=kubernetes` on a Windows host opens Kubernetes; "Preview (dry run)" says
why it is greyed; Roles & Features shows a load error instead of "Loading catalog…" forever and Refresh re-reads
the inventory; identical role names in /role-deployments are disambiguated; IIS on Linux reads "Windows-only".

### Still missing

- 8 catalog roles bind a template that records a DIFFERENT file than a family's config path (measured: apt.conf,
  bind9, cups, frr, mariadb, mongodb, mysql-server, opendmarc — e.g. cups renders its snmp.conf template over
  cupsd.conf, frr renders frr.conf over /etc/frr/daemons). The wizard does not yet refuse these per family.
- 23 role artifacts named "P" in the dev database are leftovers of interrupted pytest runs; the UI now tells them
  apart but they are not deleted.

---

## 0.57.97 (2026-10-18) — role management and the deployment pipeline, tested end to end

Worked 2026-10-09. 20 Playwright scenarios (`bossman-ui/e2e/roles.spec.ts`, `e2e/deployments.spec.ts`) drive the
UI against the enrolled systemd test hosts — real installs, real drift, two administrators.
*Verified:* 21/21 passed (incl. setup) with 2 workers, 3.3 min.

### New

**Role bindings are approved in one place: Deploy → Change proposals.** A binding made with YOLO off waits as
"pending approval"; the queue names the role, the target, the requester and the parameters. Four-eyes is enforced
by the API (an administrator approves, never the requester — 403/409 with the reason) and shown before the click:
the requester's Approve is greyed with "another administrator must approve". *Verified:* A4 (admin binds,
admin2 approves, unbind; YOLO on → active at once).

**Deployments target OUs and Sites**, not only host / host group / all hosts — the API had all five, the form three.

**"Require approval by a second administrator"** on any deployment; for all-hosts or >10-host targets the box is
ticked and locked with the policy reason. *Verified:* B4.

**Version history of a role artifact with a diff** (Roles & Features → Version history). The diff is the plan
library's own view, extracted into one shared component (`shared/version-diff`) — one diff in the app. *Verified:* A6.

**Every deployment shows a per-host table** — host, role, phase, state and the reason (drift, not-applicable,
blocked, or "waiting for the pilot host to stay compliant for 30 s"). *Verified:* B3, B5, B7, B8.

### Changed

- Approve / Detect now / Correct drift / Uninstall are visible and greyed with their reason instead of hidden or
  answered with a 409 after the click (e.g. Uninstall of an authored role: "not a catalog role — Bossman knows no
  uninstall for it"). *Verified:* B4, B7, B9.
- The preview names hosts that are applicable only by borrowing another OS family's package names (earlyoom on
  AlmaLinux) instead of a bare "1/1 applicable". *Verified:* B3.
- Saving a `role:` in the Workflow designer says which artifact version it published (an unchanged save publishes
  none). *Verified:* A1.
- Directory import keeps the picked directory's name in plan names, reports created / updated / unchanged per file,
  and refuses — with the place — a name already taken in another folder instead of overwriting it. *Verified:* A3,
  `tests/test_plans_import_bulk.py`.
- The wizard's parameter masks carry `enum_labels` and `enum_open` from the schema, as /config-fields does.
  *Verified:* `tests/test_wizard_seed_enum_meta.py`.

### Fixed

- **Drift in a templated config file was never detected**: the engine read a top-level `changes` the agent never
  sends, so every `config_template` step reported "unchanged" — a hand-edited managed value stayed "compliant", and
  a config change notified no handler. *Measured* on e2e-deb-1 (MEMORY_MIN_PERCENT edited → still compliant);
  *verified fixed* by B7 ("drift detected in: Render configuration" → Correct drift → compliant).
- A read-only host's deployment showed "error"; it is "blocked" with the agent's reason. *Verified:* B8.
- Preview failed for catalog roles whose form carried hidden runtime values (422 "runtime role parameter(s) cannot
  be overridden"). *Verified:* B4 (memlockd).
- The Scheduler could not create any job: Create always answered "a target is required" (a cached `computed()`
  over a plain form object). *Verified:* B13.
- `61 25 * * *` was accepted as a cron and never fired; out-of-range fields are refused with the field and range,
  and a stored invalid job records "never fires — invalid cron" instead of being skipped silently. *Verified:* B13,
  `tests/test_cron.py`.
- A lint error in invalid YAML carried no line. *Verified:* A2 ("(line 4)").
- The directory-import result list was clipped below the panel's edge (unreachable). *Verified:* A3.
- Compliance Evaluate, Rollout start/abort/delete and Scheduler Run now no longer swallow errors.
- A rollout deleted or aborted during its health-gate wait no longer crashes its executor (`None.progress`).

### Still missing

- The host write gate cannot be read back: Role bindings offers "Enable writes" and "Set read-only" without
  showing which state the host is in (the agent exposes no read of its own `write` flag).
- Role bindings renders every role as a live node (~100 catalog roles, 3 requests each); the new filter narrows the
  list but the first open still loads all.
- A global deployment is previewed but not created by the e2e: approving it would install on every enrolled
  machine, including real servers.

---

## 0.57.97 (2026-10-18) — every package, configured and tested in Kubernetes (in progress)

Worked from 2026-10-09. The goal: every available package is configurable by a rule or the wizard — measured
in a real pod, not asserted from the catalog.

**Where it stands (2026-10-11, all 298 catalog roles on fresh hosts):** 238 roles reach
`compliant` through the role-deployment API (Debian 185, AlmaLinux 53), their units still running 10 s later — 76 on
the first run. 10 are named unavailable on a family, 8 merged into the role of the same daemon, 42 fail for a named
cause (site values, hardware, container, a peer service, the package's own file), none is open. *Evidence: configs/package_e2e_bossman_results.jsonl, …_baseline.jsonl.*

### New

**RedHat packages are qualified from their own RPM.** `qualify_packages --family redhat` runs the same stages
as the Debian side, grounded on the RPM's `%config` file and its own man5 page (fetched from a long-lived
AlmaLinux 9 container, ~1 s per package). Templates are `<pkg>-redhat`, offered to RedHat hosts only; a file
that already has a RedHat template, or a Debian template that renders it byte-for-line, is not duplicated.
*Verified:* bind, chrony, httpd-core, openssh-server, postfix — 5/5 correct EL paths; sshd `LogLevel` 9/9 and
`PermitRootLogin` 4/4 documented values with the RedHat default `prohibit-password`.

**Every package has exactly one route, measured from the archives.** Debian's file list now comes from the
archive's Contents index (only 2164 of 8555 Debian packages ship a configuration file under /etc at all).
*Measured:* Debian — wizard 473 · rule-template 126 · rule-codec 602 · no-config 6600 · unrouted 754;
RedHat — wizard 62 · rule-template 48 · rule-codec 920 · no-config 36 · unrouted 836
(`configs/package_e2e_worklist.json`).

**A package e2e in Kubernetes.** One fresh pod per package (Debian trixie / AlmaLinux 9 images), configured by
the agent's own modules, judged by the package's own checker and a foreground start; one of ten named
outcomes per package (`configs/package_e2e_results.jsonl`). *Verified:* nginx on AlmaLinux — defaults
reproduce the shipped nginx.conf, `worker_connections 2048` written, `nginx -t` ok, daemon alive.

**Every screen is held to the same consistency rules, by a crawler.** Playwright visits every route of the
router and checks console errors, failing API calls, accessibility (axe, WCAG AA), horizontal scroll at desktop and
phone width, disabled controls without a reason, rendered `undefined`/`NaN`, and two-click reachability with the
nav fitting 720 px. *Measured:* 1 of 58 screens clean on the first run; 57 passed, 0 failed, 2 skipped by design
after the fixes below (`bossman-ui/e2e/consistency.spec.ts`).

### Changed

**Every disabled button says why.** Preview / Create deployment, Dry run / Apply, Add user, Create token, Save,
Install + console and two dozen more show their reason on hover, computed from the same condition that disables
them. **Navigation:** the AI dashboard is in Monitor (it was reachable by no click), Event rules moved to Library
next to Event handlers, `/plans` redirects to Roles (it listed the same documents). **Colours:** the status
colours, links and hint text meet WCAG AA on the dark theme (they measured 2.8–4.4:1). *Verified by the crawler.*

**The VM lab says when it is unavailable.** `GET /api/v1/vm/status` answers `{available, reason}`; a stopped lab
container is a 503 with its reason instead of a 400, and the disk-images page shows "Lab unavailable — <reason>".

### Fixed

**cups on Debian is configurable.** The role's template rendered `/etc/cups/snmp.conf` (refused as the wrong file)
and the `cupsd.conf` template was invented (`Listen 0.0.0.0`, `Port 443`). It is now parametrized from the file
cups-daemon's postinst copies, `/usr/share/cups/cupsd.conf.default`: 10 fields, enums from cupsd.conf(5).
*Measured: with its defaults it renders the shipped file byte for byte (jinja2 and gonja); `cupsd -t` accepts
defaults and a variant with all 10 values changed; the role is compliant through Bossman.*

**hostapd's template writes only keys hostapd knows.** It wrote `wpa_disable_eapol_key_index_retry`, `dot11d` and
`dot11h` (hostapd: "unknown configuration item"; the real names are `ieee80211d`/`ieee80211h`), an empty `wpa_psk=`
("Invalid PSK ''"), and `wps_state=2` under the comment "Disable WPS" — 2 turns WPS on; 0 is off. *Measured with
hostapd itself: 5 errors → 1 with the defaults (the passphrase, a site secret, is the one left); a variant with a
passphrase and 802.11d/h parses fully and stops only at the missing wlan0.*

**A command that floods its output no longer takes the agent down with it.** hylafax-server's postinst runs faxsetup,
which ignores `DEBIAN_FRONTEND=noninteractive` and re-asks "Area code []?" forever on an empty stdin — more than 64 MB
in seconds, buffered whole, until the test host died without a log line. The agent now bounds what a shelled-out
command may write (32 MiB, far above any package listing), stops the whole process group past it (the postinst is a
grandchild of apt), and reports the last output as the reason. The pod e2e installs through the agent's package module
now, the path a managed host takes. *Measured: hylafax-server ends install-failed after 36.6 s with "produced more than
32 MiB of output and was stopped (a prompt loop? … Area code []?)" instead of a dead pod after ~890 s.* (agent 0.57.83)

**A field a host's file does not have is greyed out — and refused if set anyway.** A role's form is built from one
template, but a family may render its own: squid on AlmaLinux ships 3 directives where Debian documents 207. A value set
for a missing field used to vanish silently on that host. Now the wizard context names each family template's fields
(`family_fields`), the Add-roles form disables the rest with the reason ("Not in this host's redhat file
(/etc/squid/squid.conf) — a value here would be refused"), and the engine refuses such a value with the field named
instead of rendering without it. *Measured: on the AlmaLinux test host 205 of squid's 207 fields are disabled with that
reason, http_port and coredump_dir stay editable (Playwright); engine and context tests pass; seven AlmaLinux
family-template roles stay compliant.*

**squid, opendkim and opendmarc are configured on AlmaLinux too, with one form for both families.** Their EL
branches installed and started nothing configured. A new tool, `template_from_shipped`, makes a template from the file
a family ships — every directive a field named after the directive (`SyslogFacility` → `syslog_facility`), so the
Debian and the EL template of a role share their field names without a mapping; prose stays prose (a documentation
header counts only when the file also has a setting line for that key). opendkim had no template at all. EL's opendkim
signs with a key no step created; the role runs the package's `opendkim-default-keygen` once — which needs the host's
domain name, so on a test host without one it is named as the site value it is. *Measured: all six templates render
their shipped files byte for byte; `opendmarc -n`, `opendkim -n`, `squid -k parse` accept defaults and variants on
both families; squid, opendmarc compliant on both, opendkim on Debian.* Known limit: a family template can only use
the fields its file has — squid on EL ships 3 directives where Debian documents 207.

**Every role now restarts its daemon — and the count says what that revealed.** 44 Debian roles (5 on AlmaLinux) named
no unit: they wrote the file and restarted nothing (redis.conf changed, redis kept its old settings), and the e2e,
having no unit to watch, counted them compliant. The unit is now named from what each package ships
(`tools/debian_units.py` → `configs/debian_package_units.json`, the RPMs' own units for EL). Restarted for real, eleven
daemons refused their file: sshd's template rendered empty values (`Port `, `PermitRootLogin ` — a lockout on a real
host), mosquitto's and prometheus's and keepalived's were written for other files, sssd.conf had the wrong mode and no
domain, mariadb-server's was invented. sshd now renders each family's shipped sshd_config (checked with `sshd -t`;
EL host keys created first), mosquitto and prometheus their shipped files (`promtool check config`), keepalived and
sssd ask for their VRRP instances / domains before deploying. Five roles that were the same daemon twice are merged
(openssh-server → sshd, mariadb-server → mariadb, redis-server → redis, ntp → ntpsec, mpd → mpd.conf); mysql-server is
"unavailable" on Debian (its MySQL is MariaDB; the role wrote a file MariaDB never reads); bacula-director is "installed,
not configured" (its generated config pairs random passwords with the storage and file daemons). A test now refuses a
curation table with a repeated key — two had silently dropped a fix. *Measured: full Bossman-path re-run, then the
changed roles re-tested: 238 of 298 compliant with every unit running 10 s after the check (was 249, of which 8 were
duplicates and several never ran the role's file).*

**The DHCP server role means the same on both families — and runs on both.** On Debian it configured `dhcpd.conf`
but named no unit, so it read compliant without a running server; on AlmaLinux it had no file and started dhcpd
without a subnet. Now both families render their own file (Debian's example, EL9's stub) plus a required `subnets`
list, and both start the server. Debian's init script also starts a DHCPv6 server whenever no interface is named —
which always fails — so the role names the DHCPv4 interfaces once. The test images now carry Debian's whole
"important" tier (and EL9's equivalent base tools): without `ps`, the init script reported a running dhcpd as
failed. *Measured: dhcpd -t accepts both variants; isc-dhcp-server compliant through Bossman on Debian and AlmaLinux
with a subnet of the test network; a smoke run of nine other roles on the new images stays compliant.*

**A full re-run over all 288 active roles found five regressions; all are fixed or explained.** Three roles were
refused at preview ("role parameter 'cipher-suite-id' must be number" — ipmiseld, e2guardian, fapolicyd): the value-set
sync had copied the directive catalog's TEXT values into number fields, and the seed then made the default the string
"3". The sync now gives copied values the field's type, and the schemas were normalized. gnunet stopped right after
starting because ARM, running as `gnunet`, may not create `/var/log/gnunet.log`; the role creates it once. bip was a
one-off (compliant on the re-test). *Measured: 249 of 298 compliant after the re-run, none refused at preview.*

**biboumi gets as far as its XMPP server.** Its template invented `log_file=/var/log/biboumi/biboumi.log` (a
directory nobody creates — biboumi exited before logging why) and offered example values for the two settings the
shipped file leaves empty on purpose. Rebuilt from the shipped file, hostname and password required, and the database
directory the package does not create is created once. *Measured: defaults render the shipped file byte for byte;
with site values the daemon now stops only at "Failed to connect to the XMPP server" — a peer the test host lacks.*

**A role that needs a value only the site has asks for it before anything is deployed.** A template field marked
`required` (a tunnel address, a domain, a passphrase) is required in the wizard: the form marks it, the dry run and
the install are greyed out with the reason ("Required settings are empty — iodined: password, topdomain,
tunnel_ip"), and the API refuses the preview naming every missing value at once — instead of deploying a daemon
that cannot start and reporting its refusal afterwards. iodined is the first role to use it: its role had written an
invented template into a logcheck rule file; it now configures `/etc/default/iodine`, the file its unit reads. The
package e2e takes test site values from `configs/package_e2e_site_values.json` (documentation addresses only).
autossh, gpg-agent and talkd ship no system configuration (only a logcheck rule file) and are "installed, not
configured" with that reason. *Measured: without values the preview answers 422 "required role parameters
'password', 'topdomain', 'tunnel_ip' are missing"; with them iodined is compliant through Bossman (iodined opened
dns0 with the variant's tunnel address); Playwright: Validate/Install greyed with that reason, enabled once filled.*

**Commented settings become real fields across the reachable templates — and the queue keeps it that way.** The
same activation ran over the 182 templates the UI can reach that still had placeholders on comment lines: 49 changed
(each accepted only if its defaults still render the shipped settings), 4 left as they were because they would have
got worse, 113 named as having no shipped file at that path. The qualify pipeline's repair chain now runs the
activation on every template it writes, and a template marked `source: hand` is never regenerated by the batch —
radicale-config had been overwritten by a model draft the first time the queue restarted after it was committed.
*Measured: 8 compliant catalog roles among them stay compliant through Bossman; the pod path renders and writes all
37 affected packages.*

**The other eight inert forms are fixed or withdrawn, each with its reason.** ssmtp's role pointed at a logcheck rule
file and its template invented keys (`use_tls` — ssmtp knows `UseTLS`): rebuilt from the postinst-written ssmtp.conf
with the eleven directives of ssmtp.conf(5). syslog-ng-core's template is `/etc/default/syslog-ng` and was recorded
as syslog-ng.conf: retargeted and activated. rsnapshot (cron schedules), changetrack (tracked files) and nmh (global
aliases) render real list entries after the shipped examples. `mpd` was a second role for the daemon `mpd.conf`
already configures: merged. openiked (a site's IKEv2 policy) and epic4 (a client's startup script) are "installed,
not configured" with that reason — and the catalog's empty-path repair no longer refills a path emptied by decision.
*Measured: every rebuilt template renders its source file with its defaults (ssmtp: except the install-time
hostname, left to ssmtp); openiked compliant through Bossman.*

**Ten more forms configure something.** 18 catalog templates had every placeholder on a comment line, so their
fields changed nothing (adduser 17 fields, connman 29, logind 11, spamassassin 11, timesyncd 5, …). A general
activation (`activate_expressions`) turns each commented setting into "the live line when set, the shipped line when
unset" and wires schema fields the template never placed; ten templates are fixed this way, the eight with a wrong
target file are named below. The guard that decides "set" is written so the agent's gonja and the pipeline's jinja2
agree — gonja evaluates `[] != []` as true, which activated `KillOnlyUsers=` with nothing after it (the parity test
caught it); mopidy and hdapsd used the same guard and are corrected too. *Measured: every one keeps the shipped
file's settings with its defaults; variants pass `spamassassin --lint`, `systemd-analyze cat-config` (logind) and
`sh -n` (adduser, ucf); i2pd, spamassassin and mopidy compliant through Bossman.*

**direvent's form configures something.** Every field of its template sat on a comment line, so setting a watcher
changed nothing — and direvent 5.2 segfaults when no watcher is declared, which is exactly what the shipped file
does. The template now renders a `watchers` list (path, event, command, optional recursion, pattern, user,
timeout). *Measured: defaults render the shipped file byte for byte; with one watcher `direvent --lint` passes and
the daemon runs. Without one it still crashes — named as the site value the role needs.*

**sniproxy runs.** The role's template was `/etc/default/sniproxy` written over `/etc/sniproxy.conf`. And the
shipped `sniproxy.conf` itself is refused by its binary: Debian builds sniproxy without libudns, and the file's
`fallback localhost:8080` is a hostname. The new `sniproxy.conf` template keeps the shipped file, writes an address
there and models the three host tables as lists. *Measured: the binary loads defaults and a variant; compliant
through Bossman.*

**dns-flood-detector runs.** Its unit had two defects: it starts `/usr/sbin/dns-flood-detector` while the package
installs `/usr/bin/`, and it is `Type=notify` while the shipped options run the daemon with `-d`, which forks and
never reports ready. The role adds a drop-in (binary path + `Type=forking`) that retires itself once the package's
path is right. *Measured on a fresh host: `NotifyAccess=all` does not help, `-b` never sends READY, `Type=forking`
with the shipped `-d` runs; compliant through Bossman.*

**osmo-hlr and osmo-stp run.** Their units run as `osmocom`, which no trixie package creates (217/USER); the role
creates the system user once. Behind that, osmo-hlr's template had lost the indentation Osmocom's VTY syntax depends
on ("Error occurred during reading the below line") and osmo-stp's was invented; both are rebuilt from the shipped
files. *Measured: defaults render the shipped files byte for byte; osmo-stp binds the variant's M3UA port; both
roles compliant through Bossman.*

**mandos runs.** Its unit has `Requisite=avahi-daemon.service` — avahi must already be active — and installing
avahi does not start it, so every start ended "Dependency failed". The role enables and starts avahi first.
*Measured: compliant through Bossman on a fresh host.*

**rsync and radicale run.** Both roles wrote `/etc/default/<name>`, which their systemd units do not read. rsync now
configures `/etc/rsyncd.conf` from the package's example (its unit starts only when that file exists), radicale
`/etc/radicale/config` (77 fields generated from the shipped file) and hands its collections directory, left
root-owned by the package, to the `radicale` user once. A catalog description written as "Configure <path>" now
follows a path fix instead of naming the file the role no longer touches. *Measured: both render their source
file byte for byte; `rsync --daemon` lists the example module, radicale answers HTTP 200 with defaults and a
variant; both roles compliant through Bossman.*

**hdapsd, gammu-smsd and miredo roles write the file their daemon reads, in its syntax.** Found by reading each
role's own error next to the baseline cause: hdapsd's template wrote INI into a libconfig file ("line 5 - syntax
error"); gammu-smsdrc lacked `service` ("Service configuration is missing") and used key names gammu does not know;
miredo's role wrote `/etc/default/miredo`, which no unit reads, and its `miredo.conf` template invented directives.
All three are rebuilt from the shipped file; rbootd's role creates `/var/lib/rbootd`, which its package does not.
*Measured: each renders its shipped file byte for byte with the defaults; hdapsd reads the variant, gammu-smsd gets
to the device, `miredo-checkconf` passes the variant (rc=0); the roles now stop only at missing hardware, external
DNS (miredo) or boot images (rbootd).*

**A re-mined config path keeps what later stages decided.** When the RedHat pass mined a path Debian shares
(`/etc/ddclient.conf`), it replaced the directive entry and erased `enum_open` and 1284 keys across shared paths;
the catalog fit check failed. Re-mines now merge (marks travel with an unchanged value set; unreported keys stay).
*Measured: marks restored 179 → 188, fit check 3 passed, full suite 1948 passed.*

**The baseline reads a daemon's own log file.** svxlink's journal said only "status=1/FAILURE"; its reason
("Open capture audio device failed") was in the `--logfile` its unit names. *Measured: svxlink-server now
classifies as hardware.*

**A checker that cannot judge a row is skipped with its reason, not failed.** The pod path ran `dockerd
--validate` against `/etc/default/docker` and `nft -c` without CAP_NET_ADMIN. *Measured: docker.io, nftables and
freeradius-config now pass-unverified with the named reason; 0 validate-failed.*

**A command that fails stops the role.** A configuration check that exits non-zero (`nginx -t` rc=1) counted as a
change, so the runbook went on to restart the service with the broken file and left it stopped. *Found by the
package e2e; verified:* the nginx role on fresh Debian and AlmaLinux hosts ends `compliant`.

**A role with a validation step can become compliant.** Detection ran the "validate configuration" command in check
mode, where it is always predicted as a change: every such role stayed noncompliant forever, with no reason shown.
Commands are no longer part of detection, and a target that differs right after an apply names the steps.

**Two UI controls that could never work.** Roles & Features' Preview button never enabled, and Disk images' Save
grow policy did not react to typing: both conditions were `computed()` over plain form fields and were calculated
once. *Found by the crawler's disabled-reason rule.*

**A rendered config file now ends with the newline its template ends with.** The agent's renderer stripped it
(plain-Jinja2 behaviour; Ansible preserves it), so every file written from a template lost its final LF.
*Found by the package e2e:* haproxy refused the file ("Missing LF on last line"); after the fix
`haproxy -c` passes in the pod. Agent 0.57.75.

**The wizard renders the host's own family template.** A role names one template — the Debian one — and the
wizard used it on every family: on a RedHat host it would have written Debian's nginx.conf (`user www-data`,
`sites-enabled`). A template made for one family's file is now preferred for that file on hosts of that
family, in the direct runbook run and in role deployments (the family templates travel with the version), and it
carries its own defaults so fields the role's form does not name render their shipped values. *Verified:* the
nginx role on a fresh AlmaLinux host writes the RedHat nginx.conf and ends `compliant`.

**A role can name a family's one-time initialisation.** `families.<family>.init` in the catalog becomes a runbook
step right after the install (idempotent, skipped when empty). RedHat postgresql runs `postgresql-setup --initdb`:
EL's package does not initialise the cluster (Debian's does), so the unit refused to start on every fresh host.
*Found by the Bossman-path baseline (cause `needs-init`); pinned by tests/test_role_deployment.py.*

**"The daemon does not run" now says why.** The baseline used to file every role whose daemon fails with the
package's own configuration under "environment". Its journal now decides a named cause — `needs-site-config` (17),
`hardware` (5), `needs-peer` (3), `container` (3), `service-user-missing`, `missing-binary`, `needs-init`, `crash`,
`dependency`, `no-journal`, `unclassified` — and only three are the container. *Measured over 42 journals; table in
docs/package-config-e2e.md.* The Debian test image gained `adduser` (on every installed Debian system): without it
postinsts skipped creating service users and prometheus-exporter-exporter failed with 217/USER; it runs since.

**A resource's generation list says when it is loading or could not be read.** The inspector's Generations tab
showed "No recorded applies yet" while the list was still loading and when the request failed — three states, one
sentence, and the failure's reason was dropped. It now shows "Loading…", the error with its reason, or the empty
state. *Found by the Playwright package scenario (rollback found no generation to restore); re-run green.* The
change-proposal list is keyboard-reachable when it scrolls (axe: scrollable-region-focusable).

**Role forms validate the values they offer.** 352 number fields in 77 templates carried their default and choices
as text ("2", ["0".."4"]) and 167 bool fields carried the config's own tokens ("1"/"0", "yes"/"no"): the Roles page
refused its own defaults at preview ("role parameter 'log_level' must be number" — bip, mtpolicyd; "must be bool" —
stubby). Values now match the field type (a bool field of tokens becomes a number/string field so the file is
written unchanged); qualify normalizes every package it processes. *Measured: rendering with defaults is
byte-identical for 163 of 164 templates (lcd4linux loses one alignment space).*

**Roles that cannot be installed on AlmaLinux say so.** adminer, docker-ce, traefik, etcd, rabbitmq-server and
node_exporter are in no enabled EL9 repository, pacemaker only in the disabled HighAvailability repo — the wizard
greys them out with that reason instead of failing at `dnf install`. fail2ban (EPEL) and tftp-server (AppStream)
had been wrongly listed as unpackaged. *Measured with `dnf repoquery` in an AlmaLinux 9 container.*

**chrony, anacron, adminer.** The chrony template wrote four lines chronyd rejects (`dir`, standalone
`minpoll`/`maxpoll`, `maxsources`) — *verified with `chronyd -p` on defaults and on every branch*; anacron's role
watches `anacron.timer` (the service exits after each run by design); a role without a unit (adminer) no longer
runs `systemctl restart .service`.

**Three roles were "compliant" while nothing was configured.** samba's template was a ufw application profile
written over smb.conf (testparm accepts an unknown section); fail2ban's rendered /etc/default/fail2ban into
jail.local; php-fpm's Debian path was a pattern (`/etc/php/*/…`) written literally into a directory named `*`, and
the read-back of that same path agreed. Now: samba → the smb.conf template, fail2ban → a jail.local template,
trixie's concrete paths (php 8.4, PostgreSQL 17), and the engine refuses a destination that is a pattern. *Each
template verified with the package's checker (testparm -s, fail2ban-client -t, php-fpm -t) on both families.*

**A RedHat host gets RedHat defaults.** A role's form defaults are its Debian values; on AlmaLinux they overrode
the RedHat template's own (php-fpm: `user = www-data`). On a family template a value still equal to the role
default yields to the template's default; a changed value is kept.

**The role form offers what the template configures.** It was built from the playbook's variables alone: 94 fields
in 8 roles changed nothing (samba's `workgroup`), template fields were missing. The template's schema now defines
the fields; a playbook variable sets a default.

**Config files end with a newline, and `true | int` is 1.** 5246 of 5754 templates had no trailing LF, and the
agent keeps the template's last character — nftables refused its file. 3743 templates fixed, qualify keeps it so.
The agent's renderer answered 0 for `true | int` (acmesh wrote AUTO_RENEW="0"): its `int`/`float` give Python's
answer for booleans now (agent 0.57.78). *Found by rendering every template under the agent's renderer and the
pipeline's and comparing.*

**More templates the daemon accepts.** redis (one `save` line per rule, `requirepass` only when set, `dir`),
docker daemon.json (valid JSON, no `hosts` next to `-H fd://`), containerd (one table, TOML arrays), dnsdist
(Lua `--` comments — and a new enrich gate keeps a file's own comment syntax), inspircd (no XML closing tags),
oidentd (the inner default block), php-fpm (a real pool file per family). *Each checked with the daemon's own
parser or start.*

**The qualify service no longer crash-loops on a missing variable.** It had restarted 17 054 times since
2026-09-02 on an unset proxy variable; the environment is now checked once at start, by name.

### Still missing

- Template defects found so far: dnsmasq ("bad option at line 45"), bind9 (`named.conf.options` syntax),
  apache2 (log directory). A role (openssh-server) offers RedHat without naming the file.
- 754 Debian and 836 RedHat packages ship a config file that no route reaches yet.
- Site values shaped as FILES (swift rings, ctdb nodes, certificates, chasquid's domain directory) or as decisions
  nobody should default (enabling firehol) are not asked for yet; `required` fields cover single values only.
- 82 reachable templates keep placeholders on comment lines because no Debian package ships their target file
  (nothing to ground the activation on); EPEL's java-latest paths are pinned to a version the host may not have.

## 0.57.97 (2026-10-18) — the Kubernetes console

Worked 2026-10-09. Everything below was exercised against a real cluster — minikube v1.35.1 on the docker
driver, reached through an agent built from this tree — through the running Bossman, not against mocks.
Design and evidence: [docs/kubernetes-console.md](docs/kubernetes-console.md).

### New

**A Kubernetes cluster is a thing you register, by naming its access host.** The enrolled agent that holds
`kubectl` and the kubeconfig does every read and write; Bossman keeps no cluster credential and never
touches etcd. Reachability is a named state with its reason, and every observed fact says when it was
observed. *Verified:* registration probed minikube (v1.35.1, 1 node, 4 namespaces, 65 api-resources); an
unreachable API server and an unreachable host each answer with their own reason (pytest, 10 cases).

**An explorer that explains.** Rancher's grouping cut to what a newcomer reaches for, plus every kind the
API server serves. Each row has one of ten named states with the Kubernetes reason behind it; the inspector
turns the reason into a sentence, what to do, and the kubernetes.io page (28 reasons in
`configs/kubernetes_reasons.json`), shows spec and status apart with generation vs observedGeneration, the
field managers, the pods by selector, the events (Warnings first), the logs, and the etcd key as an
explanation of where the state lives. *Verified in the browser:* a pod with `nginx:doesnotexist` lists as
Degraded, its inspector says "Image cannot be pulled" with the fix; zero console errors.

**The Application form — a few answers become a correct set of objects.** The operator never picks a kind:
"how should it run" and "how is data kept" derive Deployment | DaemonSet | Job | CronJob | StatefulSet (with
its headless Service), and the derived kind is said. The defaults ARE the best practice: recommended
labels, a Service whose selector is generated from the workload, a resource preset, a readiness probe, the
Restricted Pod Security profile, an HPA that removes `replicas`. Pre-flight checks name their rule; the
server-side dry run per object is the second verdict; an existing workload re-opens as the form.
*Verified:* the full lifecycle, below.

**Every write is a server-side apply recorded as a generation, behind the approval gate.** Field manager
`bossman`, strict validation; outside YOLO mode an apply — a single object, a whole application, a rollback,
a scale — files a change proposal carrying the preview and records no generation until approved. Delete
previews what goes and what stays and records the deletion as a generation. *Verified:* proposals filed and
approved from both the API and the wizard; a deletion is generation 6 with `deleted: true`.

**Operator actions that are either possible or greyed out with the reason.** Restart, roll back to a
Kubernetes revision, scale, pause/resume, cordon/uncordon/drain, delete pod, suspend/resume a CronJob.
*Verified:* cordon twice → 409 "already cordoned"; restart on a ConfigMap → the kinds it applies to.

**`kubectl` is a module** (`internal/modules/kubectl.go`): structured input, read verbs run under dry-run,
writes are gated, manifests on stdin, exit codes as data with stderr as the reason. **`k8s_*` MCP tools**
let a model drive a cluster the way an operator does.

**The deployment lifecycle, proven end to end** (`tests/test_kubernetes_lifecycle_live.py`, one green run on
minikube): plan → apply → healthy → scale 3/3 → image change with a diff naming only the image → broken image
degraded with the reason → rollback via proposal → logs → edit as form → delete with preview → the deletion
in the history → namespace gone.

### Changed

- The generic Resource inspector's Values tab rendered the transport envelope (`resource_key`, `type`,
  `schema`) as three fields — for every kind. The client now unwraps `schema()` like it already unwrapped
  observe/generations. *Verified:* a Deployment's Resource tab shows its 12 typed spec fields.
- `GET /resource-kinds` lists the new kind `k8s`; the generic read route forwards `cluster`, `api_version`
  and `object_kind`. The API reference is regenerated (508 operations; tag `kubernetes`).

### Fixed

- `kubectl delete -o json` is refused by kubectl; the module gives delete `-o name`. *Measured* on the first
  live delete.
- A Deployment whose only pod sits in ImagePullBackOff listed as "Rolling out" for ten minutes; a
  progressing workload row now takes its worst pod's state and names the pod. *Measured* on `ui-check/broken`.
- The Baseline profile dropped all capabilities; per the Pod Security Standards it keeps the default set,
  and the stock nginx image exits 1 without it. *Measured* (CrashLoopBackOff, exit 1).
- The read-only root filesystem default crashed nginx-unprivileged (`mkdir /tmp/proxy_temp`); it is opt-in
  with the reason in the hint. *Measured.*

### Still missing

- Helm releases are not listed inside the explorer (the node links to the access host's Kubernetes tab);
  `SystemMember.target = k8s` has no cluster reference; clone/rehearse/promote skip k8s members.
- No `kube_*` monitoring checks yet; pod states do not reach Problems.
- The fleet's second cluster (`minikube` behind `docker-test`) was unreachable during this work — only the
  local minikube is proven.
- Lists of objects (containers, tolerations) are not editable in the generic Values tab — use the form or
  the YAML tab. No watch stream; lists are read on demand, the inventory is cached for 15 minutes.
- The mined kubeconfig template targets `/etc/kubectl`, which does not exist; the fix belongs in the
  qualify pipeline.

---

## 0.57.97 (2026-10-18) — the Windows plane, the management console, and the result log

Worked 2026-08-26 to 2026-08-28. Everything below was exercised against a real Windows Server 2022
(`bossman-wintest`) and a real Debian host, not against mocks.

### New

**A Windows agent that manages Windows, not a Linux agent in a costume.** .NET 10, WMI for measurement, and
**26 modules** exposed to the fleet under the same names Linux uses where the concept is the same
([docs/modules-windows.md](docs/modules-windows.md), generated from what the agent itself publishes):

- *Inventory and reads* — `package_facts` (installed programs from the Uninstall registry), `service_facts`
  (240 services with start mode, PID and run-as), `getent` (the local SAM in passwd/group layout),
  `storage_facts` (disks and partitions in lsblk's shape), `windows_eventlog` (+ its channel list),
  `windows_gpresult`, `pending_reboot`, `windows_capability`.
- *Declared state* — `user`, `group`, `registry`, `service`, `windows_feature` (roles and features, 265 of
  them, with Windows' own seven install states), `package` (with an explicit provider and a mandatory
  detection rule), `scheduled_task`, `share`, `windows_firewall_rule`, `windows_iis`, `windows_dns`,
  `windows_dhcp`, `timezone`, `environment`, `file`, `copy`, `command`, `powershell`.
- Every write module is **idempotent and previewable**: it reads the host, compares, reports
  `changed: false` when nothing had to happen, and `dry_run: true` returns the plan. Verified per module —
  create, second identical call, remove.

**The agent is installed, not copied.** A Windows service (`UseWindowsService`), an idempotent
`install-agent.ps1`/`uninstall-agent.ps1`, and — as of 2026-08-28 — a **verified MSI**. Proven with a real
reboot (host up 20:25:30, agent process 20:25:35, unattended) and with the package's own acceptance test,
`packaging/verify-msi.ps1`, passing all seven checks on the host: silent install, service Running **and**
`/healthz` answering 0.2.0, the entry in Programs and Features, a second install that upgrades in place with
one product and one service, an uninstall that removes service/binaries/entry, and a state directory that
survives it. The test host now runs the MSI-installed agent and Bossman polls it.

Getting the package built at all needed a Windows build host, because `wix` on Linux declares its own behaviour
undefined and proved it. So the test host was made into one **through the agent**: the corporate proxy
configured with the `environment` module (machine-wide variables) and `netsh winhttp` (for services), then the
.NET SDK and WiX installed over it. The first time this system set up its own build host — and the reason the
MSI is verified rather than merely authored.

**The management console — MMC's snap-in tree, for every managed host** (`/mmc`, 19 snap-ins declared in
[configs/mmc_snapins.json](configs/mmc_snapins.json)). Console tree, result list, actions on the selected row;
each snap-in names its MMC counterpart on Windows (services.msc, lusrmgr.msc, eventvwr.msc, diskmgmt.msc,
fsmgmt.msc, wf.msc, inetmgr, dnsmgmt.msc, dhcpmgmt.msc, taskschd.msc, appwiz.cpl, rsop.msc, perfmon.msc,
taskmgr). **Linux hosts use the same tree** — 15 snap-ins available on the Windows host, 5 on Debian, and the
rest say what they need. Create dialogs are **generated from each module's own input schema**, so a form can
neither offer a parameter the module would refuse nor miss one it requires.

**The result log** — every module call leaves a record that can be fetched afterwards and reasoned over: a
ring buffer in **both** agents (`GET /api/v1/audit`), the `operation_log` table collected per boot with a
`gap` marker for records lost before collection, `GET /api/v1/operations`, the MCP tool
`operation_log(host, module, outcome, since_minutes, changed_only)`, and a **Result log** page in the UI next
to the Audit log. Eight outcomes, none interchangeable — `planned` is a dry run, `refused` is the host saying
no, `error` is the agent breaking, and **`timed-out` may have completed**.

**Group Policy in the document, as a foreign authority's intent.** `windows_gpresult` records which GPOs apply
and which were denied and why; `GET /api/v1/agents/{id}/policy-conflicts` compares our declared registry
values against Windows' policy territory. Verified: `AUOptions` declared 4 and held 3 out of band → one
finding with the sentence an operator needs; both at 4 → `same_value`, never a conflict.

**A hand-written check, assigned through the UI** ([the guide](docs/checks-authoring.md)):
`yoloman_agent_selfcheck` measures how fast a host's own agent port accepts a local connection — the floor
under every other check. Assigned via OU / Policy with its generated parameter form, staged, applied, and
verified: `OK, 0.208 ms` on the first cycle.

**A published site: [imoes.github.io/yoloman](https://imoes.github.io/yoloman/)** — GitHub Pages serving `/docs`
from `main`, so the presentation and the screen list are pages rather than source listings. Verified after
publishing: both pages, all three screenshots and every link answer 200. Links that leave the site do so on
purpose and say why — Pages serves only `/docs` and does not render markdown, so `.md` documents point at
GitHub's rendered view.

**Documentation that cannot go stale, and that an AI can work from.** All of it prose, all of it generated
from the running system except the one page that is deliberately hand-written:

- **[The developer guide](docs/developing.md)** — what the system is, where truth lives for each kind of
  fact, the **nine contracts** that must not be broken (idempotence, the target's own words unmapped, nothing
  vanishing silently, a refusal naming its reason, the two configuration write paths, values-not-text,
  policy precedence, no `max_tokens`, one name per thing), how to add a module / check / endpoint / snap-in,
  the twelve traps that already cost real time here, and a closing section addressed to a **language model**
  working in the repository.
- **[The HTTP API, endpoint by endpoint](docs/api-reference.md)** — all **481 operations in 68 groups**, each
  group opening with one sentence saying what it is *for*, each endpoint with its parameters described in
  words. Generated from a **running** server's `/openapi.json`, not from the source, because a route the
  router never included does not exist for a caller — a measurement that caught exactly that twice. It also
  reports its own gap: **201 of the 481 handlers carry no docstring**, and those are marked as such rather
  than padded with invented prose. **33 were written in the same pass** — the whole four-verb resource plane
  (docker, helm, config, package, service, role), login, the fleet listing, and the monitoring endpoints an
  operator lives in — each by reading the handler and *verifying* every claim against the code. Four of those
  first drafts asserted behaviour the code does not have, and finding them is the argument for the exercise:
  - `dry_run` **defaults to `true`** on every resource apply, so an apply that omits it reports success and
    changes nothing. Now said at every one of them.
  - A config rollback keeps **unlimited** generations — nothing prunes `resource_generations`. The
    30-generation cap that exists belongs to the *docker* desired-state model and does not apply here; the
    draft had claimed it did.
  - Check-rule `PUT` carries a `version`, and **nothing checks it** — two editors do not collide, the second
    write wins silently. The draft had called it optimistic concurrency.
  - An acknowledgement is cleared on the next **confirmed (hard) state change**, recovery *or* fresh onset,
    not "when the service recovers" — which is the more useful fact, because it is what stops a stale ack
    from silencing a new problem.
- **[Windows modules](docs/modules-windows.md)** and **[Linux modules](docs/modules-linux.md)** from the
  agents' own tool listings, **[every screen](docs/frontend-presentation.html)** (54, in five workspaces,
  each description taken from the component's own source comment), and a
  [landing page](https://imoes.github.io/yoloman/) that says what the product is — and that it is vibe coded
  and in development — before it lists features.

**The JSON copies were dropped.** Each module reference used to ship twice, markdown "for people" and JSON
"for machines". That was a misunderstanding of the machine reader: a model needs to know what a module or an
endpoint is *for*, what it refuses, and which of two similar ones is right — `{"type": "string"}` answers none
of those, while the prose page answers all three. The second file could only repeat the first less readably
and drift from it. Machine-readable, here, means **prose that is generated**.

### Changed

**Resource generations are capped at 30, and a pruned rollback target says it was pruned.** Nothing ever
removed a row from `resource_generation`: every resource apply added one and none were deleted, so a resource
applied on a cycle grew the table without bound. Honestly measured before the change: **one row, one
resource** — this prevents a problem rather than cleaning one up, and the rows being small is exactly why it
would have gone unnoticed until it did not. The cap is the same 30 the docker desired-state model uses, and
pruning happens **in the same transaction as the insert**, so a crash cannot lose the new generation or
delete history for one that was never written. Numbering keeps climbing (1…35 with 30 rows kept) because a
reused generation number would point a stored rollback reference at a different spec. And a rollback to a
dropped generation answers *"generation 3 has been pruned — only the newest 30 are kept and the oldest still
held is 7"* instead of "no such generation": a trimmed history and a typo are different problems, and this
project's rule is that nothing vanishes silently.

**`If-Match` now guards the PARTIAL edits too — and a claim in this changelog was wrong.** The previous
entry said "a check rule's `version` is not enforced". It was: `PUT /api/v1/check-rules/{id}` had honoured
`If-Match` all along, and the grep behind that claim looked for a 409 while the code answers **412**. What
was actually missing is narrower and worse placed: **both `PATCH` routes** — check rules and notification
rules — took a partial edit with no version check while every `PUT` in the API had one. That is the wrong way
round, because a partial edit is where a lost update is most likely: two people changing *different* fields
of one rule each believe they are safe, and neither was warned. Both now call the same
`api/etag.py:check_if_match` the PUTs use — a stale version is refused with 412 and told to re-read, no
header still writes (the guarantee is for clients that send one, not a new requirement). Both tests were
checked by removing each guard in turn and watching the matching test fail.

**Every one of the 481 API operations is now described.** The reference counted its own gap — 234 handlers
without a docstring when it was first generated — and that number is what closed it: 143 descriptions written
in this pass, in batches, each claim checked against the code or the database before it went in. The page
still counts, so the next endpoint added without a docstring shows up in it.

Nine claims of my own fell over while being checked, and each correction is in the endpoint's own
documentation: a check rule's `version` **was** enforced on PUT all along (the grep behind "not enforced"
looked for a 409 while the code answers 412) — what was missing is both **PATCH** routes, now fixed; a
runbook's lint validates the document's *shape* and not module existence; `channel` and `target` on a
notification rule are validated **separately**, so an email address in a webhook rule is accepted and fails
at dispatch; a graph whose host disappears returns an **empty series** rather than dropping the line; and
saved searches are tenant-shared rather than per-user. Also corrected in passing: a comment claiming
`POST /api/v1/enroll` is "only mounted when enroll_secret is configured" — enrolment is open and it is mounted
unconditionally, which a live 422 confirms.

**The flaky monitoring test is fixed, and it was competing with real policy.** One arbitrary test in
`test_monitoring.py` failed per full-suite run — a different one each time, each passing in isolation. Cause:
its helper created a **global** check rule for `CPU load`/`cpu_pct`, and the shared database also holds real
non-default global and site rules for exactly that pair (measured: 80/95 global, 70/90 site, grading ten live
hosts). Whichever won depended on resolution order. The test rules are now scoped to each test's own host, so
they win by precedence without touching the live policy — which stays, because it is somebody's monitoring
and not test residue.

**An event rule's `mode` now does what its name says.** `mode: auto|propose` was validated strictly,
stored, and read by **nothing** — the engine gates on `autonomy: propose|auto_verify` alone, so a rule set
to `mode: "auto"` only ever proposed. It is now an alias, and the direction of its fallback is the whole
safety of it: `mode` defaults to `"auto"` in the payload while `autonomy` defaults to `"propose"`, so
deriving from a *defaulted* `mode` would have promoted **every** rule that sends neither field from "suggest
a fix" to "apply it unattended". `model_fields_set` distinguishes sent from defaulted; `autonomy` wins when
both are sent (the UI's own create form sends `mode: "auto"` beside `autonomy: "propose"`, and refusing that
pair would break a screen for a contradiction it never intended); and the response **derives** `mode` from
`autonomy`, so a row written before the alias cannot report two answers to one question. Verified live in
five cases: neither field → propose, `mode: auto` alone → auto_verify, contradictory pair → propose, and a
`PUT` without either field does **not** escalate. The regression tests fail if the naive alias returns —
checked by reintroducing it. The UI stops sending `mode` (it never had a control for it, only a help string
that was never rendered).

**`GET /api/v1/me` no longer claims rights the server refuses.** It selected an API token's access
grants by **name** while the host ACL selected them by the token's **UID** — so a token sharing a name
with a granted one was told `scope: all` and then refused with 403 by every route that acts. Measured on
the running server before the fix (two tokens named the same, one grant): `/me` → `["all"]`, the
manage-gated call → 403. Both paths now go through one predicate (`grant_filter` in `services/auth.py`),
so they cannot disagree again, and a regression test fails if the old behaviour returns — verified by
reintroducing it. Grants also expose `subject_token_id` now, because that, not the name, is what decides
authorisation, and two grants can carry the same `subject_ref` with one of them bound to a dead token.

- **The Logs screen reads the event log on Windows** and journald on Linux, through one endpoint and one entry
  shape. A syslog priority is *translated* to Windows levels (0–2 → critical, 3 → error, 4 → warning,
  inclusively upward), not passed through — an untranslated number filtered on a level that does not exist and
  answered "no problems".
- **Well-known principals resolve through their SID.** "Everyone" is *Jeder* on a German host, and
  `-ReadAccess "Everyone"` failed there. A declaration written once now works on any installation language,
  and the idempotence check compares through the same translation.
- **`windows_feature` can list.** `name` used to be required, so the console's Roles and Features node had to
  already know every name — a catalogue that only answers about things you can name is not an inventory.
- The Windows agent's `/healthz` reports its **own** version (0.2.0), so the fleet's version column stops
  showing whatever the host was enrolled with.
- Milestone 6's *generated wrappers* became a **shared skeleton** (`DeclarativeModule`) after measuring: eight
  modules, 379–554 lines each, all repeating the same seven steps, and **not one** a thin shell over a cmdlet.
  Generated modules would have been uniform and wrong.

### Fixed

Each of these was invisible until a real host was in front of it:

- **A NUL byte in an agent's reply aborted the whole poll cycle's COMMIT.** Windows registry strings carry a
  trailing C-string terminator; Postgres cannot store U+0000, and asyncpg raised at commit time — discarding
  that host's metrics, checks, inventory and policy every 60 seconds with only a traceback to show.
- **`_store_facts` deleted facts it does not own**, so `group_policy` vanished every tick and its six-hour
  throttle stamp with it (8 gpresult reads in 25 minutes).
- **A host with metrics older than a day could not be deleted at all** — the cascade ran into a
  non-cascading foreign key, and the 500 said nothing an operator could act on.
- **The stale-series prune failed on the very foreign key it was written to avoid**, so per-process series
  were never pruned.
- **The policy conflict report confirmed itself**: it compared against the registry area a declared resource
  writes into, and called a match "Group Policy agrees". Measured: `gpresult /X` carries no per-setting data
  on this host at all.
- **`-Write` produced a read-only agent** — PowerShell binds `,` looser than `+` in an array literal, so
  `AGENT_WRITE=` and `true` became two entries.
- **The tool endpoint flattened arrays with `ToString()`**, so every list parameter of every module arrived as
  JSON text (`["Administratoren"]` as a group name).
- **A task result overflowed `[int]`** (Windows returned 2147942402) and one unlucky task killed the whole
  scheduled-task inventory.
- **A firewall rule reported "changed" forever**: Windows stores `192.0.2.0/24` as `203.0.113.0/255.255.0.0`.
- **`-RepetitionInterval` without `-RepetitionDuration` repeats for one day only** — an interval task would
  have quietly stopped.
- **`windows_gpresult` failed as a service**: as LocalSystem `gpresult /X` writes no file for the default
  scope, and the module reported a file-not-found for a file gpresult had declined to produce.
- **A multi-step apply that failed halfway reported only stderr**, so a call that had created an account and
  then failed on the group looked like nothing had happened.
- **The Result log's filter box typed and filtered nothing**, and the event log's Event ID was read from the
  wrong key so every row looked like a log without event ids.
- **A rejected check was pushed silently.** The agent validates each pushed module and reports failures inside
  a 200 response; Bossman looked only at the HTTP status, so a check that failed validation was refused AND
  THE HOST KEPT RUNNING THE PREVIOUS VERSION — a service state reporting an error from source that no longer
  existed. The per-module results are read now, every rejection is logged with its reason, and a rejected
  check is not run: its service says "this host rejected the check when it was pushed".

### Still missing

- **DHCP: creating an ACTIVE scope is not verified.** The read path, the dry-run plans and the refusals are;
  activation answers every DHCPDISCOVER on the segment and is an operator's decision, so a new scope is
  created **inactive** unless activation is stated.
- **The eight older Windows modules have not been migrated onto `DeclarativeModule`.** Each is host-verified,
  and rewriting a working host-tested module without the host in front of you is a regression taken for
  tidiness. They migrate one at a time, with their verification re-run.
- **WiX v6+ requires accepting the Open Source Maintenance Fee agreement**; the build pins v5.0.2 (MS-RL).
  Worth a decision before anyone automates the MSI build in CI.
- **The MSI build needs a Windows host.** `wix` on Linux declares its own behaviour undefined and proved it —
  three inconsistent path-validation failures. The build now runs on the test host; a Windows CI runner is the
  durable answer.
- **Three tests in `test_reconciler.py` need the stack quiet, and say so.** There is one database — this
  installation *is* the test system — and the live `bossman` container attaches a reconciler that `LISTEN`s
  on `bossman_outbox`. `enqueue_policy_event` sends a `pg_notify` on commit deliberately, so the live worker
  wakes first, takes the outbox row `FOR UPDATE`, and the test's `process_outbox_once` (`SKIP LOCKED`) gets
  nothing. The tests now ask `pg_stat_activity` whether a listener exists and **skip with that reason plus
  the way around it**, instead of failing with `assert 0 >= 1` — which reads like a broken reconciler and is
  not one. Verified: with `docker compose -p agentic-mcp stop bossman` all three pass, and the stack is
  healthy again afterwards. **No second database**, deliberately: a second Postgres would be a second truth
  to keep migrated and seeded, and the cost here is twenty quiet seconds per change to the reconciler.
- Snap-ins for what has no module yet: printers, certificates, local security policy, Windows Update.

---

## Earlier work

This file starts with the work above. Everything before it is in the git history, and the design documents
carry the reasoning: [docs/windows-management.md](docs/windows-management.md),
[docs/windows-agent.md](docs/windows-agent.md), and the rest of [docs/](docs/).
