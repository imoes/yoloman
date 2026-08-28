# Changelog

What yoloman can do that it could not do before — grouped by effect, not by file. Commits explain changes to
code; this explains changes to the **product**.

**Every entry names its evidence.** "Verified on the real host", "measured", or the number that was counted.
An entry without evidence is a statement of intent, and this file is not for those.

Sections per release: **New** · **Changed** · **Fixed** · **Still missing**. The last one is the important one —
a gap that is written down is not a surprise.

---

## Unreleased — the Windows plane, the management console, and the result log

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

**Documentation that cannot go stale:** [Windows modules](docs/modules-windows.md) and
[Linux modules](docs/modules-linux.md) generated from the agents' own tool listings, and
[an HTML presentation of every screen](docs/frontend-presentation.html) — 54 screens in five workspaces, each
description taken from the component's own source comment — a [landing page](docs/index.html) that says what
the product is (and that it is vibe coded and in development) before it lists features, and the same module
references **machine-readable** beside the human ones ([.json](docs/modules-windows.json)), generated in one
pass so the two cannot disagree.

### Changed

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
- **A firewall rule reported "changed" forever**: Windows stores `10.32.0.0/16` as `10.32.0.0/255.255.0.0`.
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
- Snap-ins for what has no module yet: printers, certificates, local security policy, Windows Update.

---

## Earlier work

This file starts with the work above. Everything before it is in the git history, and the design documents
carry the reasoning: [docs/windows-management.md](docs/windows-management.md),
[docs/windows-agent.md](docs/windows-agent.md), and the rest of [docs/](docs/).
