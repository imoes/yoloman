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
4. ~~**`windows_capability`** (DISM)~~ — **DONE 2026-08-27.** Both DISM inventories in one module (`kind:
   capability | optional_feature`), never merged with `windows_feature`'s Server roles: three inventories,
   three cmdlets, three state vocabularies, and Windows keeps them apart. Verified on the host — an installed
   capability reports `already present (Installed)`, `TelnetClient` went Disabled → **Enabled with
   awaiting-restart**, the second run said `already present`, and `NetFx3` was refused before anything was
   attempted with *"is DisabledWithPayloadRemoved: its payload has been removed from this image, so
   installing it needs `source`"* — the case the whole design was built around, found in the wild.

   **Three measurements it took to get existence right**, and each wrong attempt is in the code as a comment:
   `Get-WindowsCapability -Online -Name "Totally.Made.Up.Name"` returns an OBJECT with `State: NotPresent`, so
   state cannot distinguish "unknown" from "not installed"; the echoed `Name` cannot either, because with
   `-Name` it is EMPTY even for a real capability (the first fix keyed on that and refused every valid name);
   the full list is **316 entries in 0.5 s** and there `Name` is populated, so the lookup goes through the
   list.

   **And RSAT is not a capability on Server.** This host's 316 capabilities are languages, fonts and the like
   with no `Rsat.*` among them at all — on Windows Server the RSAT tools are `windows_feature` entries
   (`RSAT-AD-Tools`). The refusal message says so, because "not in the list" without that hint sends the
   reader looking for a typo.

   Also fixed here, and it is the more important half: **`Add-WindowsCapability` has no `-NoRestart`
   parameter**. My command carried one, PowerShell raised a ParameterBindingException, powershell.exe still
   exited 0, and the module reported **"installed"** for a capability whose state was unchanged. Two guards
   now: the bridge wraps every setup in `try/catch` with an explicit `exit 1`, so a terminating error can no
   longer pass as success; and the module fails when the state after the call does not match the request —
   the same "the exit code is a claim, the state is the evidence" rule `package` had from the start and this
   module shipped without.
5. **The snapins**, in the order the fleet needs them: IIS → DHCP → DNS → SMB → scheduled tasks → firewall.
   Each one's FieldSpec generated from `Get-Command`, so the console is typed on the first try.
6. **The generated wrappers.** Tier-2 modules that are a thin shell over one cmdlet family are declared in a
   table (module name, cmdlets, key parameters, idempotence rule) and generated, because 40 hand-written
   near-identical modules is 40 chances to spell `state` differently.
7. **MSI packaging of the agent itself** + service registration — the milestone 6 of `windows-agent.md`, and
   the thing that makes all of the above installable rather than copied.

8. ~~**The declared-registry resource + the GP conflict report.**~~ — **DONE 2026-08-27.** A registry value is
   a first-class desired-state resource (`type: "registry"`, one value per row, per-key `source` from the
   group < OU < site < host merge), the agent applies it through `POST /api/v1/state/apply`, and
   `GET /api/v1/agents/{id}/policy-conflicts` compares it against Windows' policy territory from stored data
   with no host call. Verified on `bossman-wintest`: `AUOptions` declared 4, held 3 out of band → one finding;
   both at 4 → `same_value`, never a conflict.

   **Four defects it took to get an honest report**, each invisible from the Linux side:

   - **`effective_resources` overwrote the declared `type` with `"config"`**, so a registry declaration was
     invisible to the very report built on it (`kind = strongest.get("type") or "config"`).
   - **A NUL character in the agent's reply aborted the COMMIT.** Windows registry strings carry a trailing
     C-string terminator; Postgres cannot store U+0000 in `text`/`jsonb`, and asyncpg raised
     UntranslatableCharacterError at commit — discarding that host's ENTIRE poll cycle (metrics, checks,
     inventory, policy) every 60 seconds with only a traceback to show for it. Scrubbed once where an agent's
     JSON becomes Python data.
   - **`_store_facts` deleted facts it does not own.** Foreign keys were a hardcoded list of two names, so
     `group_policy` made the change comparison compare the whole facts document against the inventory
     document (differing every tick) and was then dropped by the rewrite — erasing the six-hour throttle
     stamp, hence 8 gpresult reads in 25 minutes. The owned key set is recorded now (`_inventory_keys`).
   - **The report confirmed itself.** It compared against a field called `settings` and called a match
     "Group Policy agrees". Measured: `gpresult /X` here carries NO per-setting data at all (element census:
     ExtensionGuid, ExtensionName, ExtensionStatus — no RegistrySetting anywhere), so the values come from the
     Group-Policy-OWNED REGISTRY AREA — which a declared registry resource writes into as well. After
     applying our own declaration the area held our value, and the report found agreement with the value it
     had just written. Now: `policy_area_values` (named for what it is), outcome `same_value` instead of
     `agreeing` with the caveat spelled out, a differing value worded as *"Another authority holds AUOptions
     = '3' … that value is not ours — we would have written ours"*, and `imposed_source` travelling with the
     report so no consumer overstates it. `IMPOSED_SOURCE_RSOP` is wired and tested for the day a source can
     name the author per value.

9. ~~**THE RESULT LOG — retrievable, and analysable by the AI**~~ — **DONE 2026-08-27**, all three layers:
   a ring buffer in BOTH agents (`GET /api/v1/audit`, identical wire shape), the `operation_log` table
   collected by the poller with a per-boot cursor, `GET /api/v1/operations` + `/api/v1/agents/{id}/operations`,
   the MCP tool `operation_log(host, module, outcome, since_minutes, changed_only)`, and a **Result log** page
   in the UI next to the Audit log. The human and the AI read the SAME rows — a summary written for one and a
   record kept for the other is how the two end up disagreeing about what happened.

   **Eight outcomes, and no two of them may be collapsed:** `changed`, `unchanged` (the idempotence claim),
   `planned` (a DRY RUN — a preview, not a no-op), `refused` (the host said no, its words carried through),
   `error` (the agent broke — about us, not the host), `timed-out` (**may have completed**, measured: the SNMP
   install did), `unknown-module`, and `gap` (Bossman's own marker for records lost from a ring before
   collection — a log with an unmarked hole invites exactly the conclusion it cannot support).

   **It paid for itself in its first hour**, which is the argument for having it: five `unknown-module` records
   in two minutes showed that Bossman polls `package_facts` on every host every cycle, that the C# agent had no
   such module, and that the poller's best-effort catch had been swallowing it for a week — so
   `facts.installed_packages` was empty for every Windows host and compliance, the capability matcher and the
   package catalogue all saw nothing. Fixed in the same session (`PackageFactsModule`, the Uninstall registry).
   A second defect fell out of the same look: the collector ran only for non-infra agents, silently excluding
   the SNMP/SSH poller that executes every agent-less device's checks.

   Original scope, for the record:

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

## 7a. The event log — filtered on the host, for both readers

Asked for directly: the AI must reach it through the agent, filter warnings and critical, and so must a
person — with the categories selectable. Measured on `bossman-wintest` first, because two of the numbers
decide the design:

    channels                    406 exist · 83 hold records · 38 544 records in total
    the fullest channel          Microsoft-Windows-SystemDataArchiver/Diagnostic, 22 512 records
    a FILTERED query             System+Application, levels 1-3, 7 days, max 50  ->  50 events in 0.04 s
    LevelDisplayName             LOCALISED — this host says "Fehler", "Warnung", "Informationen"
                                 …and measurably EMPTY for 4 events at level 4
    level 0                      exists (8 events), display name "Informationen"

**The filter runs in the query.** `Get-WinEvent -FilterHashtable` is evaluated inside the log service, which
is why it costs 0.04 s; shipping a channel and filtering afterwards would move megabytes to save nothing, and
the fullest channel on a fresh install is diagnostic noise nobody asked for.

**The level vocabulary is ours, the numbers are Windows'.** A dashboard filtering on "Error" finds nothing on
a German host, so the API takes and returns canonical names (`critical, error, warning, information, verbose,
log_always`), filters on the number, and carries all three: `level` (authoritative), `level_name` (stable
across languages — the one to read) and `level_display` (what this host calls it, possibly empty). Level 0 is
named rather than quietly excluded by a `1,2,3` filter: it is `LogAlways` in the schema and providers use it
for whatever they like.

**"Warnings and critical" is not what an operator means.** The default is `critical,error,warning`, because
ERROR is the commonest of the three by an order of magnitude — measured on this host, 126 errors and 126
warnings against **zero** criticals in thirty days. A filter offering only warning and critical would have
shown half the problems and nothing at all of the most common kind.

    windows_eventlog            read entries; levels, logs, since, provider, event_ids, contains, max_events
    windows_eventlog_channels   the categories with record counts, size and RETENTION
    MCP: windows_event_log(host, levels, logs, since, provider, contains, max_events)
         windows_event_log_channels(host, only_with_records, name_like)

Both are **read-only** (`Writes = false`), so they are offered even when the write gate is closed: asking a
host what went wrong must never require permission to change it. Every reply carries `by_level` and
`by_provider` counts so "who is producing these" needs no second call, and `capped` — because a capped answer
that looks complete is the one failure mode a log reader must not have.

`retention` (Circular | AutoBackup | Retain) travels with each channel, since it is the field that says
whether "the event is not there" means *it never happened* or *it has already rotated away*.

## 7b. Group Policy: Windows keeps it, but `gpresult` is part of the document

The operator's decision, and it is the right one: **we do not author or manage GPOs.** Windows keeps that
(GPMC, Active Directory). A second authority writing Group Policy would be two systems declaring the same
thing, and the domain would win every argument anyway.

**But the RESULT belongs in the host's state document**, and its place there needed naming, because it is
neither of the two things the document already holds:

| | what it is | who declared it |
|---|---|---|
| desired state | what this host SHOULD be | **us** |
| `foreign_policy` (gpresult) | what this host should be | **Active Directory**, and we do not control it |
| observed state | what this host actually IS right now | nobody — it is a measurement |

So it lands as its own section, `foreign_policy`, with `authority: windows-group-policy` and
`managed_by_us: false` travelling *with the data* rather than being implied by where it sits.

**Why it earns a place at all:** where a GPO and our own declared config touch the same setting, the GPO wins
on the host, and a convergence run fights it on every pass — forever, silently, with somebody watching a
value revert and no explanation anywhere in the system. A document that showed only our own intent could not
express that conflict. This is the intension/extension rule with a second author: two rules, one instance,
and the losing rule has to be visible.

Verified on `bossman-wintest` (a workgroup host, so local policy only):

    windows_gpresult (read-only)   2 GPO(s) applied, 0 denied (domain Local)
                                   authority windows-group-policy · managed_by_us false · SOM Local
    stored by the poller           facts.group_policy, refreshed every 6 hours (gpresult costs 1.8 s / 48 kB)
    in the document                desired-state section `foreign_policy`, beside config / inventory / …

**Two parsing traps, both measured.** The XML's element names are PARTLY LOCALISED — this host's extension
sections are called *Gruppenrichtlinieninfrastruktur* and *Richtlinien der lokalen Gruppe* — so the parser
reads only schema-stable elements (`GPO`, `Name`, `Path/Identifier`, `Link`, `SOM`, `IsValid`, `AccessDenied`,
`FilterAllowed`) and never a display name; one keyed on German names would break on an English host. And a
GPO's display name is editable while its GUID is not, so the identifier is what is recorded.

**Denied GPOs are reported, not filtered away**, each with which of the four causes applied: access denied,
security filtering, a disabled link, or an invalid GPO. "Not in the applied list" and "refused for this host,
because…" are different facts, and only the second one can be acted on — that is the whole reason this is a
module and not a grep of the applied names.

**What the policy actually imposes travels with it** — and NOT from gpresult, which was measured and found
wanting: its XML on this host carries **zero** `RegistrySetting`/`Policy`/`SecuritySettings` elements (the
extension sections are empty when nothing is configured, and where they are populated their element names are
localised). So the values are read where a GPO actually writes them:

    HKLM\SOFTWARE\Policies                                    68 keys, 15 values
    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies   11 keys, 42 values
    plus the HKCU equivalents                                 -> 57 values in total

Real ones, from the host: `Microsoft\TPM\OSManagedAuthLevel = 5`, `WindowsUpdate\AUOptions = 3`,
`safer\codeidentifiers\authenticodeenabled = 0`. **57 values against this machine's 324 000 registry keys**
is the entire argument for reading the policy subtree rather than the hive (§8a): a comparison against 57 is a
report, a comparison against 324 000 is noise.

### The conflict report is blocked, and the blocker is on OUR side

The payoff of all this would be: *"Group Policy sets `AUOptions = 3`; you declare `AUOptions = 4`; the GPO
wins, and your convergence will fight it forever."* Both halves are needed for that sentence, and only one
exists. **We have no declared-registry resource type.** The config plane declares FILE paths; the `registry`
module can *write* a value imperatively (a runbook step, an MCP call), but nothing DECLARES one, so there is
no "our side" to compare against.

That is the same gap §8a already named from the other direction — "declared keys → desired state … what is
missing is the resource type so they converge". It is one piece of work serving two purposes, and it has to
come before the conflict report rather than alongside it: a comparison needs two operands.

Recorded rather than half-built, because a conflict report against an empty set of declarations would report
zero conflicts on every host and look like good news.

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
