# Windows management: roles, features, packaging, snapins

> The goal the operator set: **a full Ansible for Windows** — roles and features as desired state, packaging
> of in-house programs (MSI, EXE, batch, PowerShell), and the config snapins. This document is the design,
> and it is grounded in what a real host answered: every number below was measured on
> `bossman-wintest` (Windows Server 2022 Standard, PowerShell 5.1, WMF/CIM, 8 GB), not read from a manual.
>
> Agent design and milestones 1–4: [`windows-agent.md`](windows-agent.md). The Linux equivalents this must
> stay identical to: [`roles-and-features.md`](roles-and-features.md), [`web-server-snapins.md`](web-server-snapins.md).

## 1. What the host actually says

    Get-WindowsFeature                265 features, 13 installed
      FeatureType                     20 Role, 90 Role Service, 155 Feature
      InstallState                    SEVEN values, read from the enum on the host — not three:
                                        0 Available   1 Installed   2 UninstallPending  3 InstallPending
                                        4 NotPresent  5 Removed     6 Unknown
                                      2 features are "Removed" today, and an uninstall left two at
                                      "UninstallPending" while a restart was outstanding
      per entry                       Name, DisplayName, FeatureType, Installed, InstallState, Depth,
                                      DependsOn, Parent, SubFeatures

    Install-WindowsFeature -WhatIf    Web-Server -IncludeManagementTools  ->  15 features
      Success / ExitCode              True / Success
      RestartNeeded                   **Maybe**        ← not a boolean. Windows' own third value.

    packaging, on a FRESH Server 2022
      msiexec.exe                     present
      dism.exe                        present
      PackageManagement (OneGet)      present — Get-Package / Install-Package
      Appx                            present
      winget                          **NOT present**   (ships with Win11 / Server 2025, not 2022)
      choco, scoop                    NOT present       (third-party, must be bootstrapped)
      installed-product inventory     3 entries from the registry Uninstall keys, each with an
                                      UninstallString — NOT from Win32_Product (enumerating it triggers an
                                      MSI self-repair of every installed package: a write disguised as a read)

Two of those measurements overturn what the milestone plan assumed yesterday: **winget is not there**, so a
`package` module that maps to winget would be a module that does not work on the operating system we are
targeting; and **`RestartNeeded: Maybe`** is a real value, so a boolean "needs reboot" would have to invent
one of two lies.

## 2. Logic audit of this design (`/logik`)

Applied to the design before writing it, because two of the findings change the model rather than the code.

### [Identity] `role` and `feature` already mean something else here

    Beleg:   docs/roles-and-features.md — a ROLE is "install + service + monitoring check + notification
             route", a FEATURE is "install the package, then its config is editable"
             Get-WindowsFeature.FeatureType — Role | Role Service | Feature, Windows' own taxonomy
    Problem: one word, two meanings, in the same UI. A "Windows Feature" (155 of them, e.g. .NET
             Framework 4.8) is not a yoloman feature, and "Web Server (IIS)" is a Windows *Role* AND a
             yoloman role — which makes the collision look like agreement exactly where it is not.
    Fix:     the Windows taxonomy keeps Windows' name under its own key. `windows_feature` is the MODULE;
             the catalogue entry carries `families.windows.feature_type: role|role_service|feature` as
             DATA about the target, never as the catalogue's own `kind`. The catalogue's `kind` stays what it
             is on Linux, so one host page cannot show two different meanings of the same word.

### [Excluded middle] `Removed` and `Maybe` are states, and a boolean erases both

> **And there were seven, not three.** The design named `available | installed | removed`; the real host's
> enum has `Available, Installed, UninstallPending, InstallPending, NotPresent, Removed, Unknown`, and an
> uninstall on the test box produced `UninstallPending` on the first try. It arrived in the API intact —
> **because the module passes Windows' string through instead of mapping it onto our own enum.** That is the
> rule paying for itself: a state nobody anticipated survived, where a mapping would have coerced it to the
> nearest known value or dropped it. The lesson is stronger than the fix: don't enumerate the target's states
> in your own type unless you are prepared to be wrong about the count.

    Beleg:   InstallState = Removed on 2 features of this host; RestartNeeded = Maybe from -WhatIf
    Problem: a model with `installed: true|false` cannot express "the payload is gone from the image, so
             installing needs a source" — it reports Available, and the install then fails with a message
             about a missing source that nothing predicted. Same for a reboot flag: Maybe is the honest
             answer for a feature install, and both `true` and `false` are wrong.
    Fix:     `install_state` is WINDOWS' OWN WORD, lower-cased and passed through — not mapped onto an enum
             of ours, for the reason in the box above. `restart_needed: yes | no | maybe` likewise. The UI
             shows "payload removed — needs a source" as its own badge, "uninstall pending — restart
             outstanding" as another, and "may need a restart" as its own wording.

### [Sufficient reason] asking for one feature installs fifteen

    Beleg:   Install-WindowsFeature Web-Server -IncludeManagementTools -WhatIf -> FeatureResult of 15
    Problem: an operator who ticks "Web Server" gets fifteen features and a possible reboot. Applying that
             without showing it is a change nobody consented to, and afterwards nothing says which of the
             fifteen were the request and which were consequences.
    Fix:     `-WhatIf` IS the plan, and it is what Apply shows: the 15 names, `RestartNeeded`, and which
             were pulled in by DependsOn versus asked for. Windows hands us a real dry run — a better one
             than the Linux side has for apt — so the preview is not a rendering of our intent but the
             system's own answer.

### [Contradiction] "installed" while the service does not exist

    Beleg:   RestartNeeded = Maybe, and a feature install that defers work to the next boot
    Problem: between install and reboot, `Get-WindowsFeature` says Installed and the role's service is
             absent — so the role page would show green while the check fails, two views contradicting each
             other about one host.
    Fix:     a role binding is `converged` only when its feature is installed AND its service exists; the
             in-between is the named state `awaiting-restart`, reported by the agent (the pending-reboot
             registry keys are unambiguous) and shown as such.

### [Valid derivation] winget's absence is not a reason to guess

    Beleg:   winget NOT present on Server 2022; PackageManagement present
    Problem: "install a package" with a hidden provider preference means the same request does different
             things on two hosts, and a failure on one of them looks like a broken package rather than a
             missing provider.
    Fix:     the provider is EXPLICIT and REPORTED. `package` takes `provider: msi|installer|packagemanagement|
             winget|choco|appx`, defaults to what the host actually has (reported per host as a capability),
             and a request for a provider the host lacks is refused BY NAME — the same `supported: false`
             with a reason the module listing already uses.

### [Parsimony / intension vs extension] 122 modules is not the goal

    Beleg:   ansible.windows (67) + community.windows (55) = 122 modules
    Problem: porting all of them is a year of work whose value is unmeasured, and most of a Windows fleet is
             served by a dozen of them. A module count is a means mistaken for the end.
    Fix:     tiers by what a Windows server is asked to BE (§3), and the desired-state document stays the
             deliverable — the modules are how it converges. Where a module is a thin wrapper over one
             cmdlet, it is generated from a declaration rather than hand-written (§6).

## 3. The module set, tiered by what it is for

Names are `ansible.windows`/`community.windows` names **minus the `win_` prefix** where the concept is the
same on both platforms, and the full name where it is Windows-only. That rule is the identity rule applied:
`copy` is `copy` on both, and `win_regedit` becomes `registry` because there is nothing to collide with.

**Tier 1 — done (milestones 1–4, verified on the real host)**

| ours | ansible equivalent | how |
|---|---|---|
| `powershell` | `win_powershell`, `win_shell`, `win_command` | hosted runspace, streams separated, `$WhatIfPreference` for dry run |
| `file` | `win_file` | native .NET IO |
| `copy` | `win_copy`, `win_template` | native, idempotent by SHA-256 |
| `registry` | `win_regedit`, `win_reg_stat` | `Microsoft.Win32.Registry`, compared by type AND content |
| `service` | `win_service`, `win_service_info` | `ServiceController` + the SCM's `Start` value |

**Tier 2 — roles, features and packaging (this document's subject)**

| ours | ansible equivalent | PowerShell / API |
|---|---|---|
| `windows_feature` | `win_feature`, `win_feature_info` | `Get/Install/Uninstall-WindowsFeature` (ServerManager) |
| `windows_capability` | `win_capability`, `win_optional_feature` | `Get/Add/Remove-WindowsCapability`, `Enable-WindowsOptionalFeature` (DISM) |
| `package` | `win_package` | provider model, §5 |
| `msi` | `win_package` (MSI path) | `msiexec /i /qn`, detection by ProductCode |
| `windows_update` | `win_updates`, `win_hotfix` | Windows Update COM API (`Microsoft.Update.Session`) |
| `scheduled_task` | `win_scheduled_task`, `win_scheduled_task_stat` | `ScheduledTasks` module |
| `user`, `group`, `group_membership` | `win_user`, `win_group`, `win_group_membership` | `Microsoft.PowerShell.LocalAccounts` — LOCAL only; a domain account is a different object (§7) |
| `windows_firewall` | `win_firewall`, `win_firewall_rule` | `NetSecurity` module |
| `acl` | `win_acl`, `win_acl_inheritance`, `win_owner` | `System.Security.AccessControl` — the module `file` refuses `mode` in favour of |
| `hostname`, `timezone`, `reboot` | `win_hostname`, `win_timezone`, `win_reboot` | native |
| `share` | `win_share` | `SmbShare` module |
| `certificate_store` | `win_certificate_store`, `win_certificate_info` | `X509Store` |
| `path`, `environment` | `win_path`, `win_environment` | registry-backed |

**Tier 3 — the role-specific surfaces (drives §6's snapins)**

`iis_website` / `iis_webapppool` / `iis_webbinding` / `iis_virtualdirectory` (`WebAdministration`),
`dns_zone` / `dns_record` (`DnsServer`), `dhcp_lease` / DHCP scopes (`DhcpServer`), AD objects
(`ActiveDirectory`), `smb_share` details, `security_policy`, `audit_policy`, `psmodule` / `psrepository`.

**Deliberately not ported**, each listed with its reason the way the current refusals are: `win_say`,
`win_toast`, `win_msg`, `win_wakeonlan`, `win_rabbitmq_plugin`, `win_webpicmd` (dead tooling), `psexec`
(the agent IS the remote execution path), `win_dsc`/`dsc3` (see §8).

## 4. Roles and features as desired state

The model is the Linux one, unchanged — which is the point. `configs/package_catalog.json` grows a
`families.windows` block beside `debian` and `redhat`:

```json
"iis": {
  "label": "IIS Web Server", "category": "web", "kind": "role",
  "families": {
    "windows": {
      "features": ["Web-Server", "Web-Mgmt-Console"],
      "feature_type": "role",
      "service": "W3SVC",
      "config_path": "C:\\Windows\\System32\\inetsrv\\config\\applicationHost.config",
      "include_management_tools": true
    }
  }
}
```

- **`features` is a list**, because Windows roles are composites and `Web-Server` alone gives no management
  console. The list is what we asked for; `-WhatIf`'s fifteen are the consequences, shown separately.
- **`feature_type` is data about the target**, never the catalogue's `kind` — see the identity finding.
- **Apply is a three-step plan**: `Get-WindowsFeature` (observe) → `Install-WindowsFeature -WhatIf`
  (plan, with the full FeatureResult and RestartNeeded) → `Install-WindowsFeature` (apply), then re-observe.
  That maps one-to-one onto `docs/resource-protocol.md`'s four verbs, so a Windows role is a `Deployable`
  like any other and the Workflow Designer gets it for free.
- **Drift** is `Get-WindowsFeature` against the binding, the same intension/extension split the Linux roles
  report: the role is the rule, the feature inventory is the instance.
- **Uninstall is not symmetric and must not pretend to be.** `Uninstall-WindowsFeature` leaves the payload;
  `-Remove` deletes it and turns the state into `Removed`, from which a later install needs a source
  (`-Source`, WSUS, or the ISO). So removal is two explicit operations — `remove` and `remove_payload` — and
  the second says in the form what it costs.

## 5. Packaging: in-house programs, and the provider that is never implicit

This is the half Linux gets from apt/yum and Windows has no answer for. The design has two objects.

### 5a. `package` with an explicit provider

    provider           what it drives                          detection (is it installed?)
    msi                msiexec /i /qn                          registry Uninstall\{ProductCode}
    installer          any .exe / .bat / .cmd / .ps1            the recipe's own detection rule (below)
    packagemanagement  Install-Package (OneGet)                 Get-Package
    winget             winget install --silent                  winget list  (ONLY where winget exists)
    choco              choco install -y                        choco list --local-only
    appx               Add-AppxPackage / DISM                   Get-AppxPackage

The host reports which providers it HAS as a capability (the same mechanism as
[`lego-capabilities.md`](lego-capabilities.md)), so a plan can be checked against a host before it runs
rather than failing on it. A missing provider is a named refusal with the reason, not a silent fallback to
another one — because "it installed, just differently" is the answer nobody can audit.

### 5b. The installer recipe — an in-house program as a first-class object

An MSI is self-describing; a `setup.exe` from a supplier is not. What makes an arbitrary installer
manageable is exactly three facts nobody can derive, so they are DECLARED, once, and stored:

```json
{
  "name": "acme-warehouse-client",
  "version": "4.2.1",
  "source": {"url": "http://repo.ippen.media/acme/AcmeClient-4.2.1.exe", "sha256": "…"},
  "install":   {"kind": "exe", "args": ["/S", "/v/qn", "INSTALLDIR=C:\\Acme"], "success_codes": [0, 3010]},
  "uninstall": {"kind": "registry_uninstall_string", "args": ["/S"]},
  "detect":    {"kind": "registry", "key": "HKLM:\\SOFTWARE\\Acme\\Client", "name": "Version",
                "equals": "4.2.1"},
  "reboot":    "if_exit_code_3010"
}
```

- **`detect` is mandatory and it is the whole idempotence.** Without it "install" means "run the installer
  again", which is not a converge — it is a change on every pass, and a fleet that reports 400 changes a
  night reports nothing. Four detection kinds cover the field: `registry` (a value equals/exists),
  `file_version` (an EXE/DLL's build version — `win_file_version`'s job), `msi_product` (a ProductCode), and
  `command` (a script whose exit code decides, for the cases nothing else fits).
- **`success_codes`** because `3010` means "installed, reboot required" and treating it as failure is the
  single most common way a Windows rollout reports red on a success. The `reboot` field then says what to do
  with it, and `awaiting-restart` (§2) is where the host sits until it happens.
- **`source` carries a checksum**, and it is verified before execution. An installer fetched over HTTP with
  no hash is remote code execution with extra steps.
- **Where it lives**: `configs/windows_packages/<name>.json`, the same shape as a config template — so the
  existing editor, versioning and audit trail apply, and a recipe is reviewable in a diff.
- **A batch or PowerShell installer is the same object** with `kind: bat|ps1`, run through the `powershell`
  module, which already separates the streams and honours the timeout.

### 5c. What we do NOT build

Repackaging (wrapping a vendor EXE into an MSI with WiX/PSAppDeployToolkit) is a discipline, not a feature,
and it belongs to whoever owns the application. What this system does is **install, detect, and remove
whatever the packager produced, reproducibly** — and that is the part that is missing today.

## 6. The snapins

The pattern is [`web-server-snapins.md`](web-server-snapins.md): a per-package config console, driven by the
same FieldSpec the rest of the config plane uses. Windows differs in ONE respect that changes the design:

**a Windows role's config is usually not a file.** IIS keeps `applicationHost.config` (XML), DNS and DHCP
keep their state in the registry and their own databases, AD keeps it in the directory. So the snapin's
backing verb is not "read a file, write a file" but "run the role's own cmdlets":

| snapin | reads | writes | config surface |
|---|---|---|---|
| **IIS** | `Get-Website`, `Get-WebAppPoolState`, `Get-WebBinding` | `New/Set-Website`, `Set-ItemProperty IIS:\…` | sites, bindings, app pools, virtual dirs — and `applicationHost.config` as the template path for the whole-file case |
| **DNS** | `Get-DnsServerZone`, `-ResourceRecord` | `Add/Set/Remove-DnsServerResourceRecord` | zones, records, forwarders |
| **DHCP** | `Get-DhcpServerv4Scope`, `-Lease`, `-OptionValue` | `Add/Set-DhcpServerv4Scope` | scopes, reservations, options — and this one is the pair of the PXE work |
| **SMB shares** | `Get-SmbShare`, `Get-SmbShareAccess` | `New/Set/Grant-SmbShare*` | shares, permissions |
| **Certificates** | `Get-ChildItem Cert:\LocalMachine\My` | `Import-PfxCertificate` | store contents, expiry — feeds the existing cert inventory |
| **Scheduled tasks** | `Get-ScheduledTask`, `-Info` | `Register/Set-ScheduledTask` | the `cron` counterpart, under its own name |
| **Firewall** | `Get-NetFirewallRule` + `-PortFilter` | `New/Set-NetFirewallRule` | rules — and the agent's own rule is one of them |
| **Local users/groups** | `Get-LocalUser`, `Get-LocalGroupMember` | `New/Set-LocalUser`, `Add-LocalGroupMember` | accounts, membership, rights |
| **Windows Update** | Update COM API | install/approve | the compliance view's Windows half |

**One FieldSpec, generated from the cmdlet's own parameters.** `Get-Command New-Website | Select -Expand
Parameters` yields names, types, `ValidateSet` values and mandatory flags — which is *exactly* a FieldSpec,
from the system rather than from an LLM. That is the same "the description already says the values" lever
that closed the enum gap on Linux, and here it is authoritative rather than inferred: a `ValidateSet` IS the
closed enumeration this project spent a week learning to recognise in prose.

## 7. Decisions that are decisions, not details

- **Local ≠ domain.** `user` manages local accounts. An AD account is a different object with a different
  lifecycle and a different authority, so it gets `ad_user` and cannot be reached by adding a `domain:`
  parameter to `user` — that would be one name for two things in the one place where the mistake creates
  accounts.
- **A reboot is never implicit.** `reboot: false` is the default everywhere; a module that needs one reports
  `awaiting-restart` and stops. The one exception is an explicit `reboot` module call in a runbook, where the
  operator wrote it down.
- **`ValidateSet` beats a hand-written enum**, always. Where a cmdlet declares its values, the FieldSpec
  takes them verbatim and the catalogue records that it did (`source: validateset`), so nobody re-mines what
  Windows already states.
- **DSC is a target, not a dependency.** `win_dsc` exists in Ansible because Ansible has no agent on the box.
  We do. Driving DSC resources is a possible Tier-3 module for the cases where only a DSC resource exists
  (SQL Server, Exchange), and never the mechanism for the modules above.

## 8. Milestones

1. **`windows_feature`** — observe / plan (`-WhatIf`, all 15) / apply / drift, with `install_state` and
   `restart_needed` as the three- and three-valued states they are. Verifiable on `bossman-wintest`:
   install IIS, read the plan first, see `awaiting-restart` if it says Maybe.
2. ~~**`families.windows` in the package catalogue**~~ — **DONE 2026-08-27.** 15 curated entries (IIS, DNS,
   DHCP, AD DS, File Server, Print Server, NFS, Hyper-V, WSUS, RDS, SNMP, .NET, Failover Clustering, Windows
   Backup, Containers), and **all 18 distinct feature names verified against the real host's 265-entry
   inventory** rather than typed from memory. The Windows host now resolves as
   `family: windows`, **15 exact / 487 unknown**, and a Linux role seen from Windows says
   `installable: false — the catalog has no package names for this entry in any family`.

   Three fixes were needed under it, each a defect the first Windows host exposed:

   - **The whole fleet read this host as Debian.** `family_of()` ends in `return "debian"` for anything it
     cannot identify, and the C# agent's overview carried no inventory at all. The agent now reports one, with
     **the fleet's own key names** (`os.id`, `cpu.threads`, `memory_mb` — the first draft invented
     `os_release`, `cpu_count`, `memory_total_bytes`: one fact under two names, in the very place a Windows
     and a Linux host are supposed to look like the same kind of thing).
   - **`host`, not `name`.** Bossman's `_ingest_hosts_overview` starts with `host_name = host.get("host")`
     and *continues* when it is absent — so an entry keyed `name` was skipped in silence: no facts, no
     checks, and the host kept reading as Debian while the agent served a perfectly good inventory. The Go
     agent's `HostSnapshot` has said `json:"host"` all along.
   - **No substitution across the Linux/Windows line, in either direction.** The catalogue's fallback exists
     because a Linux package name often transfers (nginx, postfix, samba are the same word on Debian, RHEL
     and SUSE — measurably for 27 roles). Between Linux and Windows nothing transfers, so a fallback there is
     not a hedge but a wrong answer with a caveat attached. `_NEVER_SUBSTITUTES` makes it `unknown` instead,
     which is visible as a gap rather than as a plausible lie.
3. **`package` with the provider model** + `msi` + the installer recipe (`configs/windows_packages/`), with
   detection and `success_codes`. The measurable claim: install an in-house EXE twice and see
   `changed: false` on the second pass.
4. **`windows_capability`** (DISM) — for the `Removed` payload case and the client-side optional features.
5. **The snapins**, in the order the fleet needs them: IIS → DHCP → DNS → SMB → scheduled tasks → firewall.
   Each one's FieldSpec generated from `Get-Command`, so the console is typed on the first try.
6. **The generated wrappers.** Tier-2 modules that are a thin shell over one cmdlet family are declared in a
   table (module name, cmdlets, key parameters, idempotence rule) and generated, because 40 hand-written
   near-identical modules is 40 chances to spell `state` differently.
7. **MSI packaging of the agent itself** + service registration — the milestone 6 of `windows-agent.md`, and
   the thing that makes all of the above installable rather than copied.

8. **THE RESULT LOG — retrievable, and analysable by the AI** (asked for 2026-08-27). Every module call must
   leave a record that can be fetched afterwards and reasoned over, not just a reply to whoever happened to
   be waiting.

   The gap, measured: the Go agent audits every tool call (`cfg.Audit.LogCall(identity, name, writes,
   changed, params, start, err)`), the **C# agent audits nothing**, and Bossman's `call_agent_tool` route
   returns the result to its caller and stores it nowhere. So today the answer to "what did that install
   actually do" exists only in whatever terminal ran it — and for the two operations that matter most
   (`windows_feature`, `package`) the interesting part is exactly the part that scrolls past: the 15-feature
   plan, the exit code, the detection rule's before/after, Windows' own refusal text.

   What it has to carry, because these are the things an analysis needs and a message does not preserve:

   - the call: host, module, parameters (secrets redacted), who asked, when, how long
   - the verdict: changed / unchanged / refused / timed-out — and **timed-out is its own outcome**, since a
     timed-out write may still have completed (measured: the SNMP install did)
   - the evidence: exit code, the detection rule's answer before and after, the plan the system itself
     produced (`-WhatIf`), and the target's own error text verbatim
   - the follow-on state: `awaiting-restart`, and what a re-read showed
   - a stable id, so a later analysis can point at one call rather than describe it

   Where: agent-side ring buffer (`GET /api/v1/audit`) so a host can be asked directly, plus a Bossman table
   so a fleet-wide question is one query. Exposed to the AI as an MCP tool (`operation_log(host, since,
   outcome)`) — the point is that the AI reads the same record the operator does, not a summary of it. That
   is the [[project-killer-feature]] applied to actions rather than to config: a fleet that can explain what
   it did.

   It comes AFTER the module work it records, because a log of operations nobody can perform yet is a schema
   with no evidence behind it — but it comes before the documentation, since the docs should describe a
   system that can already answer for itself.

## 8a. Is the registry a desired-state object? Measured, and the answer is "declared keys, never the hive"

Asked directly: how big is a Windows Server's registry, and would mapping it into desired state be worth it —
only if it does not blow the frame. Measured on `bossman-wintest`, a nearly bare Server 2022:

    hive files            SOFTWARE 69.8 MB · COMPONENTS 36.0 MB · SYSTEM 14.8 MB · DRIVERS 3.3 MB
                          DEFAULT/SAM/SECURITY ~0.1 MB each · NTUSER.DAT 0.8 MB   ≈ 125 MB in total
    HKLM\SOFTWARE          323 995 keys, ~826 000 key+value lines
                          a PowerShell provider walk did NOT finish in 120 s; `reg query /s` took 180 s
    HKLM\SYSTEM\…\Services  2 841 keys / 11 040 values — walked in 2.7 s
    HKLM\SOFTWARE\Policies   83 lines. That is the entire policy surface a GPO writes.

**So: the whole registry, no.** 324 000 keys on an EMPTY server is four orders of magnitude more than
everything this system currently manages — the whole config catalogue is 3 272 fields across 1 622 templates,
and a host's desired-state document is kilobytes. Three minutes to enumerate one hive rules it out as
something a converge run touches, and a 70 MB blob per host per generation rules it out as something to store.

**And it was never the question.** Desired state does not copy `/etc` either; it manages **declared** files.
The registry belongs in exactly the same way, and then the numbers are trivial:

| | what | measured cost |
|---|---|---|
| **declared keys → desired state** | the registry values a policy sets, as resources with generations and rollback — the `registry` module already writes them, what is missing is the resource type so they converge | the size of what you declare |
| **bounded subtrees → observed state** | `…\Services` (2 841 keys, 2.7 s), `…\Policies` (83 lines), `Uninstall` (already used for the software inventory), `Run`/`RunOnce` (autostart) | seconds, kilobytes |
| **the hive** | a full copy or diff | 70 MB and 3 minutes — **not built** |

The distinction is the same one the config plane already makes and the reason it works: a value nobody
declared is not drift, it is the operating system. Reading everything would produce a diff whose every line is
noise, which is how a drift report becomes something people turn off.

## 9. Open questions

- **The reboot boundary in a runbook.** A role that needs a restart splits a play in two. Bossman has no
  "continue after reboot" primitive yet; the closed-loop verify plane is the nearest thing and probably the
  right home for it.
- **Where the installer binaries live.** A recipe points at a URL with a hash; the fleet needs a place to
  serve them from. The PXE container already serves HTTP on the lab segment, and `deploy-artifacts/` already
  holds packages — but an in-house software repository is its own decision.
- **Whether `template` renders on the agent or the server.** Still open from `windows-agent.md`, and IIS's
  XML config is the case that will decide it: an XML config is not a line-oriented file, so the codec plane
  needs an XML codec (`win_xml`'s job) before a template is the right tool at all.
