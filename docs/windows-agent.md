# The Windows agent

> Decisions taken 2026-08-26. The Linux agent (`cmd/agentic-mcpd`, Go) is untouched by this document — the
> point of the design is that Bossman needs **no** Windows special case.

## The decision, in one paragraph

A native Windows agent in **C# / .NET**, which collects its monitoring data with **WMI queries**, carries a
module that **executes PowerShell**, gives the Linux module library **PowerShell counterparts under the same
module names**, applies **roles and features** as desired state the way the Linux roles do, and both **ships
as an MSI** and **installs MSI packages**. It speaks the REST contract the Go agent already speaks, so it
enrolls, is polled, is configured and is remediated by exactly the code paths that serve a Linux host.

## What must not change: the contract

Bossman talks to an agent through a small, already-fixed surface. The Windows agent implements the same one;
anything it cannot answer answers with a *named* absence, never with silence.

| Endpoint | What Bossman does with it | Windows source |
|---|---|---|
| `POST /api/v1/enroll` | mTLS enrolment, agent identity | same, cert store instead of files |
| `GET /api/v1/metrics` | the poller's metric pull (cursor-based) | WMI |
| `GET /api/v1/hosts/overview` | fleet table, satellites | WMI + registry |
| `GET /api/v1/net/connections/dump` | `host_edges`, the relationship view | `GetExtendedTcpTable` / ETW |
| `GET /api/v1/state`, `POST /api/v1/config/apply` | desired state, config write (codec merge / template render) | same |
| `POST /api/v1/modules/apply` | every action, incl. dry-run | PowerShell + native |
| `GET /api/v1/tools`, `/api/v1/config-templates/index` | the self-describing catalogue | same JSON |

The module protocol is the contract that matters most, because the whole action plane hangs off it
(`internal/modules/module.go`): `Name`, `Description`, `InputSchema`, `Writes`, `Run(params, dryRun)`. A C#
`IModule` with those five members is the port; nothing above it changes.

**Identity (A = A).** A module name means the same thing on both platforms or it gets a different name. `file`
with `state: absent` deletes a path on both. `service` with `state: started` starts a service on both. What
Windows genuinely has no counterpart for is not silently reinterpreted — see the next rule.

**Excluded middle (A ∨ ¬A).** A Linux-only module (`apt`, `systemd`, `selinux`, `lvol`) must be *listed* on a
Windows host with `supported: false` and a reason, not absent from `GET /api/v1/tools`. A missing entry is
indistinguishable from an old agent; "not applicable on this platform, because … " is a state an operator and
an LLM can both act on. Same for the reverse on Linux (`windows_feature`, `msi`, `registry`).

## Why C# / .NET and not Go

The two interfaces this agent is *made of* are first-class in .NET and awkward everywhere else:

- **WMI/CIM** — `Microsoft.Management.Infrastructure` (the modern MI/CIM API over the same WMI repository
  that `Get-CimInstance` uses). Typed results, no text parsing, no `wmic.exe` (deprecated and removed on
  current Windows).
- **PowerShell in-process** — `System.Management.Automation`: run a script in a hosted runspace and get back
  **objects with their streams separated** (Output/Error/Warning/Verbose/Information), not a merged stdout to
  regex. That distinction is what makes a PowerShell module reportable rather than a shell escape.

Everything else follows: WiX/`Microsoft.Build.Msix` for MSI packaging, `System.ServiceProcess` for the
service host, the Windows event log, and the AD/DISM/Failover-Cluster APIs when we get there. .NET 8+,
published `win-x64` self-contained single-file so the host needs no runtime install.

> Note: the tooling is not on this dev host (`no dotnet`, `no pwsh`, `no wix`). The build will need
> `dotnet-sdk-8.0` locally for the parts that are OS-independent, and a Windows target to test WMI at all —
> which is the same "test on real targets, not on hacks" rule the rest of this project follows.

## Monitoring data: WMI, and the query is part of the answer

Every metric records the class and property it came from, so a number's origin is reachable — the same
**sufficient reason** rule the config catalogue follows. A metric whose query returned nothing reports
`data_source: {attempts, produced}` exactly as the Starlark modules already do, so "the class is not present
on this SKU" is distinguishable from "the value is zero".

| Linux metric | Windows source (WMI/CIM class) |
|---|---|
| `cpu_percent`, per-core | `Win32_PerfFormattedData_PerfOS_Processor` (`PercentProcessorTime`, `Name` = core / `_Total`) |
| `mem_*` | `Win32_OperatingSystem` (`TotalVisibleMemorySize`, `FreePhysicalMemory`), `Win32_PerfFormattedData_PerfOS_Memory` |
| `swap_*` | `Win32_PageFileUsage` |
| `disk_usage_*` per mount | `Win32_LogicalDisk` (`Size`, `FreeSpace`, `DriveType = 3`) |
| `disk_io_*` | `Win32_PerfFormattedData_PerfDisk_LogicalDisk` |
| `net_*` per interface | `Win32_PerfFormattedData_Tcpip_NetworkInterface` |
| `load_*` | no counterpart — reported as a **named absence**, not as 0 (Windows has no load average; the honest substitute is processor-queue length, reported under its own name) |
| `uptime` | `Win32_OperatingSystem.LastBootUpTime` |
| `process_*` per (pid, comm) | `Win32_Process` + `Win32_PerfFormattedData_PerfProc_Process` |
| services | `Win32_Service` (`State`, `StartMode`, `PathName`) |
| logged-on users, sessions | `Win32_LogonSession`, `Win32_ComputerSystem` |
| installed software | `Win32_Product` is **avoided** (it triggers an MSI self-repair on every enumeration); the registry `Uninstall` keys are the correct source |
| patch state | `Win32_QuickFixEngineering`, and the Windows Update COM API for pending |
| event log | `Get-WinEvent`/`EventLogSession`, not WMI — WMI's `Win32_NTLogEvent` is orders of magnitude slower |

The two entries that are *not* WMI are there on purpose: a design that says "everything via WMI" and then
quietly uses something else for the two heavy cases would be a claim the code contradicts.

## The PowerShell module

`powershell` is the counterpart of the Linux `shell`/`command` modules and the substrate the ported modules
are written on.

- Runs **in-process** in a hosted runspace (no `powershell.exe` per call), so streams stay separated and
  typed objects survive: `Data` carries the output objects, `Msg` the error/warning streams.
- `dryRun` maps to `-WhatIf` where the cmdlet supports it and to a **refusal** where it does not — a module
  that cannot preview must say so rather than run and report "would have".
- `Writes() == true`, so it is only registered when the write gate is open, exactly like the Linux writing
  modules.
- Constrained-language / execution-policy questions are decided by the *agent's* runspace configuration, not
  by the script — the agent is the trusted process, and per-script policy would be a lie about what it can do.

## Module parity

The library is one vocabulary (~700 modules). The port is not "all of them", it is: the modules a Windows
host is actually asked to run, under their existing names.

| Module | Windows implementation |
|---|---|
| `file`, `copy`, `stat`, `find`, `unarchive` | native .NET IO; ACLs where Linux has mode bits |
| `lineinfile`, `replace`, `blockinfile` | native |
| `template` | the same gonja/Jinja templates — **rendered server-side or by the agent?** see open questions |
| `service` | `System.ServiceProcess` + `Win32_Service` (`state`, `enabled` = `StartMode`) |
| `systemd` | listed, `supported: false` — the concept is `service` here |
| `package` | winget for the modern path, `msi` for the packaged path (below) |
| `apt`, `yum`, `dnf`, `zypper` | listed, `supported: false`, reason given |
| `user`, `group` | local accounts via `Microsoft.PowerShell.LocalAccounts`; AD accounts are a *different* module, because a domain account is not a local one (identity rule) |
| `hostname`, `timezone`, `reboot` | native |
| `firewalld`, `ufw`, `iptables` | listed, `supported: false`; `windows_firewall` is the Windows module |
| `cron` | `scheduled_task` (Task Scheduler) — a different name, because the semantics differ |
| `lvol`, `filesystem`, `parted` | Storage Spaces / `Get-Disk`/`New-Partition`; the disk-management plan (`docs/disk-management.md`) applies unchanged in shape |
| new: `windows_feature` | roles and features, below |
| new: `msi` | install/remove an MSI package |
| new: `registry` | a registry value as desired state |
| new: `windows_update` | patch state and installation |

## Roles and features as desired state

`Install-WindowsFeature` / `Add-WindowsCapability` / DISM are the mechanism; the model is the one that
already exists (`docs/roles-and-features.md`, `configs/package_catalog.json`). A Windows entry gets a
`families.windows` block next to `debian` and `redhat` — same shape, same `packages`/`service`/`config_path`
keys, so the wizard, the role bindings and the compliance view need no new concept. A *role* is still
"install + service + check + notification route"; a *feature* is still "install it, then its config is
editable".

**Intension vs extension** stays visible the same way: the role is the rule, `Get-WindowsFeature` is the
instance, and the drift between them is the report.

## MSI, both directions

1. **The agent ships as an MSI** (WiX): service registration, firewall rule for its listener, its config
   directory and cert store, per-machine install, silent `/qn` for unattended deployment, and a clean
   upgrade path (same UpgradeCode, versioned ProductCode) so `self-update` works the way the .deb/.rpm path
   already does.
2. **The `msi` module installs MSI packages** — `msiexec /i /qn` with the transform/property arguments as
   typed parameters, idempotent against the installed-products registry, dry-run reporting what would be
   installed. This is the Windows equivalent of the offline `.deb`-grounded install path the provisioning
   modules use.

## Checks

The check catalogue is Starlark and platform-agnostic by construction; a Windows check's *commands* are
PowerShell/WMI instead of `/proc` and CLI tools. The retranslation work
([[project-check-retranslate]], `docs/checkmk-checks.md`) is the model: a check declares what it reads, and
the reading is per-platform. Nothing about thresholds, discovery or notification changes.

## Milestones

1. ~~**The skeleton speaks the contract**~~ — **DONE 2026-08-26**, and proven on the LINUX dev host against
   the running Bossman before any Windows VM existed: `csharp-agent-dev` enrols, is polled, and 6 metrics
   with per-volume labels are in the database. Two things the contract required that this document had not
   said: Bossman polls over **https with a client certificate** (the agent serves TLS and pins the public
   key from the enrolment reply — the DER SPKI, not the certificate, so re-issuing around the same key does
   not break it), and it was doing so **through the corporate proxy**, which answered 403. The proxy fix
   brought a real host (`pxe-lab`) back after weeks.
2. **WMI collector** — the table above, with `data_source` and per-metric provenance. **Written and
   compiling** (`AgenticMcp.Agent.Windows`, 9 queries); it cannot be RUN anywhere but on Windows, so it is
   not yet measured. `net10.0-windows` is a second target of the same host process, so the WMI collector is
   an extra collector rather than a second agent.
3. **`powershell` module** in a hosted runspace, streams separated, dry-run honoured or refused.
4. **The first ported modules** — `file`, `copy`, `service`, `registry`, `msi` — and the `supported: false`
   listing for the Linux-only ones.
5. **Roles and features** — `windows_feature`, `families.windows` in the catalogue.
6. **MSI packaging** and `self-update`.
7. **Config**: the codec/template write paths against Windows config files (INI, XML, registry) — the
   registry is the interesting one, because it is a *config file that is not a file*.

## Open questions

- **Where does `template_render` run?** Rendering server-side and shipping bytes avoids a second gonja
  implementation in C#; rendering on the agent keeps the two agents symmetrical. The measured argument wins,
  and the measurement is "does any template need host facts at render time".
- **eBPF has no Windows counterpart.** Connection edges come from `GetExtendedTcpTable` polling or ETW; the
  latency figure the Linux agent reports may simply be absent — and then it is absent by name.
- **Domain vs local.** An AD-joined host's users, groups and policies are not the host's. That is a
  separate object, not a flag on this one, and it needs its own decision before `user` grows a `domain:`
  parameter.
