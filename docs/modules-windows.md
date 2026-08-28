# Windows modules — the Ansible-shaped action plane

> **GENERATED** by `scripts/generate-module-docs.py` from what the agent itself publishes
> (`GET /api/v1/tools` on `bossman-wintest`), on 2026-08-28. Do not edit by hand: the next run
> overwrites it, and the point of generating it is that this page cannot disagree with the agents.

## What this is

Every module this platform's agent exposes **right now**, with the parameters the module itself
declares. A module is the unit a runbook step, a console action and an MCP tool call all use — the same
name, the same parameters, on every host of this platform.

**34 modules**: 19 that change the host, 15 that only read it. 7 are listed but not usable on this host (see below).

Two rules hold for all of them, and they are why the tables below are worth reading rather than
skimming:

1. **Every write module is idempotent and previewable.** It reads the host first, compares, and reports
   `changed: false` when nothing had to happen. `dry_run: true` returns the plan instead of applying it.
2. **The target's own words are passed through, not mapped.** Where Windows says `InstallState:
   Removed` or `RestartNeeded: Maybe`, that is what the module reports — a boolean would have to invent
   one of two lies.

The other platform's page: [Linux modules](modules-linux.md).

## The module catalogue is a different thing

Bossman also holds an Ansible-compatible module **catalogue** — 2128 specs,
693 of them translated into executable form (`GET /api/v1/modules`).
That is a library of specifications; this page is what an agent will execute if you call it today. The
two are deliberately not added together: one impressive number would answer neither question.

## Listed but not usable here

A module the agent knows about and cannot run **stays in the listing with its reason** — an
omission would leave a caller unable to tell "this system cannot do it" from "this host cannot".

| Module | Why not |
|---|---|
| `apt` | Windows has no APT package database |
| `cron` | Windows schedules work with triggers, principals and conditions rather than five cron fields — a different concept, so it has a different name |
| `dnf` | Windows has no YUM/DNF package database |
| `firewalld` | firewalld is a Linux service |
| `selinux` | SELinux is a Linux kernel facility |
| `systemd` | Windows services are managed by the service control manager, not by systemd units |
| `yum` | Windows has no YUM/DNF package database |

## Modules that change the host

### `command`

Run one executable with an argument list (`argv: ["ipconfig", "/all"]`), without a shell — no pipelines, redirects or expansion; use the `powershell` module for those. Optional `chdir` and `env`. Returns {cmd, rc, stdout, stderr} and always reports changed:true, because it cannot know what the command did. `timeout_seconds` bounds the run (default 300).

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `argv` | array of string | — | The executable and its arguments, unsplit and unquoted. Preferred. |
| `chdir` | string | — | Working directory for the process. |
| `cmd` | string | — | A single command line, split on whitespace. Accepted for compatibility with the Linux module; on Windows prefer argv, because paths contain spaces. |
| `dry_run` | boolean | — | Report the command that would run, and run nothing. |
| `env` | object | — | Extra environment variables for the child process. |
| `timeout_seconds` | number | — | How long to wait before killing the process. Default 300. |

### `copy`

Write content to a path on this host, either from a local file (`src`) or given inline (`content`). An ansible.builtin.copy task, a Chef `cookbook_file`/`file` with content, a Puppet `file` with `content`, or a Salt `file.managed` translate to a call here. Idempotent BY CONTENT: the destination is hashed, and a file that already holds exactly these bytes is reported as unchanged with its checksum. `backup: true` keeps the previous content beside it with a timestamped suffix and reports the path. Parent directories are created. POSIX-only parameters (mode, owner, group) are REJECTED with a reason rather than silently dropped.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dest` | string | yes | Where to write. |
| `backup` | boolean | — | Keep the previous content beside the destination, with a timestamp, and report where. |
| `content` | string | — | The content to write. Mutually exclusive with `src`. |
| `src` | string | — | A local file to copy from. Mutually exclusive with `content`. |

### `environment`

A machine-wide or per-user environment variable. `name`, `value`, and `scope` (machine or user — REQUIRED, because the wrong one produces a variable that exists and does nothing). `state: absent` removes it. Idempotent; `dry_run: true` returns the plan. NOTE that a change reaches only processes started AFTER it: running services keep the environment they were given.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | The variable's name. |
| `scope` | one of `machine`, `user` | yes | machine (every process on the host) or user (this account only). Required — there is no safe default. |
| `dry_run` | boolean | — | Report what would change without applying it. |
| `state` | one of `present`, `absent` | — | Whether the variable should exist. Default present. |
| `value` | string | — | Its value. Required unless state is absent. |

### `file`

Ensure a path is in a declared state on this host. `state: file` (the default) requires it to exist as a file and creates an empty one if it does not; `state: directory` creates the directory and its parents; `state: absent` removes it (a directory recursively); `state: touch` updates the modification time, creating the file if needed. An ansible.builtin.file task, a Chef `directory`/`file` resource, a Puppet `file` type or a Salt `file.managed` state translate to a call here. Idempotent: `changed` is false when the path is already as requested. POSIX-only parameters (mode, owner, group) are REJECTED with a reason rather than ignored — a Windows ACL is not a mode bit, and pretending otherwise would silently do nothing.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `path` | string | yes | The path to act on. |
| `state` | one of `file`, `directory`, `absent`, `touch` | — | file \| directory \| absent \| touch |

### `group`

Ensure a LOCAL Windows group is present or absent, with its description and (optionally) its exact membership. Idempotent: read and compared first, an already-correct group reports changed:false. `dry_run: true` returns the plan. `members` absent means membership is left alone; given, it is enforced (use append:true to add only). `gid` is refused — Windows assigns the RID itself. An ansible.windows.win_group task maps here.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | The group name. |
| `append` | boolean | — | True: only add the listed members. False (default, when members is given): the list is the WHOLE membership and anything else is removed. |
| `description` | string | — | The group's description as Computer Management shows it. |
| `dry_run` | boolean | — | Report what would change without applying it. |
| `members` | array of string | — | Accounts that must be in the group. Local names, or DOMAIN\\name. Absent means membership is not part of this declaration. |
| `state` | one of `present`, `absent` | — | Whether the group should exist. Default present. |

### `package`

Install or remove software on this Windows host. `provider` is REQUIRED and explicit — msi (msiexec), installer (any exe/bat/cmd/ps1 with its own switches), packagemanagement (Install-Package), winget, choco or appx — because the same request must not mean different things on two hosts; ask for one the host lacks and it is refused by name. `detect` is REQUIRED for state:present and is the whole idempotence: registry (a value exists/equals), msi_product (a ProductCode), file_version (an EXE/DLL's version) or command (a script whose exit code decides). `source` may carry a url plus sha256, verified BEFORE execution. `success_codes` defaults to [0, 3010]: 3010 means installed and a reboot is pending, which is a success. An ansible.windows.win_package task translates directly.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `provider` | one of `msi`, `installer`, `packagemanagement`, `winget`, `choco`, `appx` | yes | Required. See the module description for why there is no default. |
| `arguments` | string | — | The installer's own switches, space-separated (e.g. "/S /v/qn"). |
| `detect` | one of `registry`, `msi_product`, `file_version`, `command` | — | Required for state:present. How to tell whether it is already installed. |
| `detect_equals` | string | — | registry/file_version: the value it must have. Omit to require only that it exists — which is a WEAKER claim, and the reply says which was used. |
| `detect_key` | string | — | registry: the key. msi_product: the ProductCode. file_version: the file. command: the script. |
| `detect_name` | string | — | registry: the value's name. |
| `name` | string | — | What this package is called, for reporting and for the provider that needs an id (packagemanagement, winget, choco, appx). |
| `path` | string | — | A local installer path (msi/installer). Mutually exclusive with source.url. |
| `source_sha256` | string | — | Checksum of the fetched installer, verified before it is executed. An installer fetched over HTTP with no hash is remote code execution with extra steps. |
| `source_url` | string | — | Where to fetch the installer from. |
| `state` | one of `present`, `absent` | — |  |
| `success_codes` | string | — | Exit codes that mean success. 3010 = installed, reboot pending. |

### `powershell`

Run a PowerShell script on this host, in-process in a hosted runspace, and return its output with the streams kept separate. This is the Windows counterpart of the `shell` and `command` modules: an Ansible `win_shell` task, a Chef `powershell_script` resource, a Puppet `exec` with a PowerShell provider, or a Salt `cmd.run` with shell=powershell all translate to a call here. Parameters: `script` (required, the code to run); `whatif` (assert that every cmdlet in the script implements -WhatIf, which lets a dry run produce a REAL preview instead of a skip); `timeout_seconds` (default 300); `working_directory` (where to run it). Returns `output` as a list of {value, type} — the objects PowerShell produced, with their type names — plus `errors`, `warnings`, `information` and `had_errors`. In dry-run mode without `whatif` the script is NOT executed and the reply says so, naming `whatif` as the parameter that would change that.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `script` | string | yes | The PowerShell code to run. |
| `timeout_seconds` | number | — | Stop the script after this long. |
| `whatif` | boolean | — | Assert that every cmdlet in the script implements -WhatIf. A dry run then runs it under $WhatIfPreference and returns PowerShell's own preview instead of skipping. |
| `working_directory` | string | — | Directory to run in. Must exist; a missing one is an error, not a silent fall back to the agent's own directory. |

### `registry`

Ensure a Windows registry value is in a declared state. `path` is the key (HKLM:\SOFTWARE\..., or the long form HKEY_LOCAL_MACHINE\...), `name` the value inside it (omit for the key's default value), `data` the content and `type` one of string, expand_string, dword, qword, multi_string, binary. `state: absent` removes the value, or the whole key when no `name` is given. An ansible.windows.win_regedit task, a Chef `registry_key` resource, a Puppet `registry_value` or a DSC Registry block translate to a call here. Idempotent: the current value is read and compared BY TYPE AND CONTENT first, and an already-correct value reports changed:false with what it holds.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `path` | string | yes | The key, e.g. HKLM:\SOFTWARE\Contoso\Agent. |
| `data` | string | — | The content to set. For multi_string, newline-separated; for binary, hex. |
| `name` | string | — | The value's name. Omit for the key's default value. |
| `state` | one of `present`, `absent` | — |  |
| `type` | one of `string`, `expand_string`, `dword`, `qword`, `multi_string`, `binary` | — | The value's type. A DWORD is not the string "1". |

### `scheduled_task`

Windows scheduled tasks. Without `name`: list every task with its triggers, the account it runs as, its last result code and next run time. With `name`: ensure it is present or absent, enabled or disabled — `command` (+ optional `arguments`, `working_directory`), `schedule` one of once, daily, interval, startup, logon, plus `start_time` (HH:mm) or `interval_minutes`, `run_as` and `run_level`. Idempotent: the task is read and compared first. `dry_run: true` returns the plan. Richer triggers and conditions are refused with a message rather than approximated. This is NOT `cron`: a scheduled task has triggers, a principal, conditions and settings, and one name for both would promise a translation that does not exist.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `arguments` | string | — | Arguments for the program, as one string (Windows passes it verbatim). |
| `command` | string | — | The program to run. Required when creating a task. |
| `description` | string | — | Free text shown in Task Scheduler. |
| `dry_run` | boolean | — | Report what would change without applying it. |
| `enabled` | boolean | — | Whether the task may fire. A DISABLED TASK STILL EXISTS, which is why this is separate from state. |
| `interval_minutes` | number | — | For `interval`: how often it repeats. |
| `name` | string | — | Task name, optionally with its folder: "Yoloman\\nightly-report". Omit to LIST every task on the host. |
| `run_as` | string | — | The account the task runs as. Default SYSTEM, which needs no stored password; a named user would, and this module does not store one. |
| `run_level` | one of `limited`, `highest` | — | highest = run with elevation. Default limited. |
| `schedule` | one of `once`, `daily`, `interval`, `startup`, `logon` | — | once (at start_time today/tomorrow), daily (at start_time), interval (every interval_minutes, indefinitely), startup (at boot), logon. |
| `start_time` | string | — | HH:mm, for `once` and `daily`. |
| `state` | one of `present`, `absent` | — | Whether the task should exist. Default present. |
| `working_directory` | string | — | Working directory for the action. |

### `service`

Ensure a Windows service is in a declared run state and start mode. `name` is the service name (not the display name); `state` is started, stopped or restarted; `enabled` is auto, manual or disabled (true/false are accepted as auto/disabled). An ansible.windows.win_service task, a Chef `windows_service` resource, a Puppet `service` type or a DSC Service block translate to a call here — and so does a `service` task written for a Linux host, which is the point of the shared name. Idempotent: the current state and start mode are read first, and each is only changed when it differs. Returns both, before and after.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | The service name, e.g. "Spooler" — not the display name. |
| `enabled` | one of `auto`, `manual`, `disabled` | — | The start mode. true/false are accepted as auto/disabled. Leave unset to only change the run state. |
| `state` | one of `started`, `stopped`, `restarted` | — | Leave unset to only change the start mode. |
| `timeout_seconds` | number | — | How long to wait for a start or stop to complete. |

### `share`

SMB shares. Without `name`: list every share with its path, description, share-level permissions and whether it is one of Windows' built-in administrative shares. With `name`: ensure it is present or absent — `path` (required when creating), `description`, and the principals for `full_access`, `change_access` and `read_access`. Idempotent: read and compared first; `dry_run: true` returns the plan. THIS MANAGES SHARE PERMISSIONS ONLY — the folder's NTFS permissions are a separate access list and the effective right is the more restrictive of the two, so a share can be read-only because of the folder while this module reports Full.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `change_access` | array of string | — | Principals granted CHANGE (read+write) share access. Absent means this list is not part of the declaration; given, it is enforced exactly. |
| `description` | string | — | The share's description, as Explorer shows it. |
| `dry_run` | boolean | — | Report what would change without applying it. |
| `full_access` | array of string | — | Principals granted FULL share access, e.g. ["Administrators"]. Absent means this list is not part of the declaration; given, it is enforced exactly. |
| `name` | string | — | Share name (without the host part). Omit to LIST every share. |
| `path` | string | — | The local folder to share, e.g. D:\\data. Required when creating. |
| `read_access` | array of string | — | Principals granted READ share access. Absent means this list is not part of the declaration; given, it is enforced exactly. |
| `state` | one of `present`, `absent` | — | Whether the share should exist. Default present. |

### `timezone`

The host's time zone. `name` is WINDOWS' own zone id ("W. Europe Standard Time"), not an IANA name — the two are different vocabularies and this module refuses an IANA name with the Windows equivalent named instead of guessing. Reading it takes no parameters. Idempotent; `dry_run: true` returns the plan.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dry_run` | boolean | — | Report what would change without applying it. |
| `name` | string | — | The Windows time zone id. Omit to read the current one. |

### `user`

Ensure a LOCAL Windows account is present or absent, with its full name, description, enabled state, password policy and local group memberships. Idempotent: the account is read and compared first, and an already-correct account reports changed:false. `dry_run: true` returns the plan. An ansible.windows.win_user task maps here. Parameters that cannot be honoured on Windows (uid, shell, home, create_home, system) are REFUSED with the reason rather than ignored. Domain accounts are out of scope: this is the local SAM.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | The account name, e.g. "deploy". |
| `append` | boolean | — | True: add to the account's current groups. False (default): the listed groups are the WHOLE membership and anything else is removed. |
| `comment` | string | — | The account's full name (the GECOS slot on Linux). |
| `description` | string | — | Windows' own Description field, shown in Computer Management. |
| `dry_run` | boolean | — | Report what would change without applying it. |
| `enabled` | boolean | — | Whether the account may sign in. A DISABLED ACCOUNT STILL EXISTS, which is why this is separate from state. |
| `groups` | array of string | — | Local groups this account must belong to, e.g. ["Administrators"]. |
| `password` | string | — | Set the account's password. Never logged, never read back — so a run that sets a password reports changed:true because it cannot know whether the old one differed. |
| `password_never_expires` | boolean | — | Whether the password expiry policy applies. |
| `state` | one of `present`, `absent` | — | Whether the account should exist. Default present. |

### `windows_capability`

Install or remove a Windows CAPABILITY (DISM on-demand payload: RSAT tools, OpenSSH, language features) or an OPTIONAL FEATURE (the classic 'Turn Windows features on or off' list: SMB1, Telnet client, .NET 3.5). `kind` is capability or optional_feature — they are separate inventories with separate cmdlets, which is why one module carries both but never merges them with windows_feature's Server roles. `name` is the DISM name (e.g. Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0, or SMB1Protocol). `state` is present or absent. `source` points at installation media, and is REQUIRED when the payload has been removed — the reply reports that state verbatim (Removed / DisabledWithPayloadRemoved) rather than as a boolean, because 'disabled' and 'the bits are gone' need different actions. Ansible's win_capability and win_optional_feature both translate here.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name` | string | yes | The DISM name. Capabilities carry a version suffix (…~~~~0.0.1.0); optional features do not (SMB1Protocol, TelnetClient, NetFx3). |
| `kind` | one of `capability`, `optional_feature` | — |  |
| `source` | string | — | Installation source for a removed payload, e.g. D:\sources\sxs. |
| `state` | one of `present`, `absent` | — |  |

### `windows_dhcp`

The Windows DHCP server. No arguments: whether it is authorized, its scopes with range, mask, state, lease duration and how many addresses are free, plus the server-level options. `scope` alone: that scope's leases and reservations. Writes: `object: scope` (create/remove/activate/deactivate a scope) or `object: reservation` (pin an address to a MAC). A NEW SCOPE IS CREATED INACTIVE unless state: active is stated — a DHCP scope answers every machine on its segment, so activating is a separate decision. Idempotent; `dry_run: true` returns the plan. Failover, policies, superscopes and vendor classes are not managed here.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `client_name` | string | — | For a reservation: a name for the reserved client. |
| `dns_servers` | array of string | — | DNS servers handed to clients (option 6). |
| `dry_run` | boolean | — | Report what would change without applying it. |
| `end_range` | string | — | Last address the scope hands out. Required when creating. |
| `ip_address` | string | — | For a reservation: the address to pin. |
| `lease_duration_hours` | number | — | Lease duration in hours. Default 8. |
| `mac_address` | string | — | For a reservation: the client's MAC, e.g. 00-15-5d-01-02-03. |
| `object` | one of `scope`, `reservation` | — | What a write targets: scope or reservation. |
| `router` | string | — | The default gateway handed to clients (option 3). |
| `scope` | string | — | The scope id (its network address, e.g. 10.32.28.0). Alone it READS that scope's leases and reservations. |
| `scope_name` | string | — | A human name for the scope. |
| `start_range` | string | — | First address the scope hands out. Required when creating. |
| `state` | one of `present`, `absent`, `active`, `inactive` | — | present creates the scope INACTIVE (it hands out nothing); active makes it answer; inactive stops it answering without deleting it; absent removes it with its leases. |
| `subnet_mask` | string | — | The scope's mask, e.g. 255.255.255.0. Required when creating. |

### `windows_dns`

The Windows DNS server's zones and records. No arguments: every zone with its type, whether it is AD-integrated or read-only, and how many records it holds. `zone` alone: that zone's records. `object: zone` + `zone` + `state`: create or remove a primary zone. `object: record` + `zone` + `name` + `type` + `value`: ensure a record (A, AAAA, CNAME, TXT, MX, PTR) exists or does not. Idempotent; `dry_run: true` returns the plan. A secondary or stub zone is read-only and a write to one is refused with that reason. This is the SERVER's data, not what this host resolves.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `dry_run` | boolean | — | Report what would change without applying it. |
| `name` | string | — | For a record: the name inside the zone ("www", or "@" for the zone itself). |
| `object` | one of `zone`, `record` | — | What a write targets: zone or record. |
| `state` | one of `present`, `absent` | — | Whether the zone or record should exist. Default present. |
| `ttl_seconds` | number | — | Time to live. Default 3600. |
| `type` | one of `A`, `AAAA`, `CNAME`, `TXT`, `MX`, `PTR` | — | The record type. Required for a record write. |
| `value` | string | — | The record's data: an address for A/AAAA, a target for CNAME/MX/PTR, the text for TXT. |
| `zone` | string | — | The zone name, e.g. example.com. Alone (without `object`) it READS that zone's records. |

### `windows_feature`

Ensure Windows Server roles, role services and features are installed or absent. `name` is one feature or a list of them (the ServerManager names, e.g. Web-Server, DNS, AD-Domain-Services); `state` is present, absent or absent_with_payload (which deletes the feature files, so a later install needs a source); `include_management_tools` adds the role's consoles; `include_sub_features` adds everything under it; `source` points at an installation source for a feature whose payload was removed. An ansible.windows.win_feature task translates directly. READS FIRST, ALWAYS: the reply carries `install_state` (available|installed|removed), `feature_type` (Role|Role Service|Feature) and, for a change, the FULL list of features Windows says it would touch plus `restart_needed` (yes|no|maybe) — a dry run returns exactly that and changes nothing. Idempotent: a feature already in the requested state reports changed:false.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `include_management_tools` | boolean | — | Add the role's management consoles. `Web-Server` alone gives no IIS manager, which is the commonest surprise on a fresh install. |
| `include_sub_features` | boolean | — | Add everything beneath the named feature. |
| `installed_only` | boolean | — | Listing mode only (no `name`): return just the installed features instead of all 265, so a caller asking what is installed is not handed the whole catalogue to filter. |
| `name` | string | — | One feature name, or several separated by commas. ServerManager names, not display names — `Web-Server`, not `Web Server (IIS)`. |
| `source` | string | — | Installation source (a mounted ISO's sources\sxs, or a WSUS path) — required only for a feature whose payload was removed. |
| `state` | one of `present`, `absent`, `absent_with_payload` | — | present \| absent \| absent_with_payload. The third one deletes the feature files (Uninstall-WindowsFeature -Remove): the state becomes `removed` and a later install needs `source`. |

### `windows_firewall_rule`

Windows firewall rules. Without `name`: list every rule with its direction, action, enabled state, profiles and — joined from the separate filter objects — its ports, protocol, program and remote addresses. With `name`: ensure a rule is present or absent and enabled or disabled — `direction` (inbound/outbound), `action` (allow/block), `protocol`, `local_port`, `remote_address`, `program`, `profile`. Idempotent: read and compared first; `dry_run: true` returns the plan. NOT `firewalld`: zones and services do not translate to profiles and rules, so each platform keeps its own module.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `action` | one of `allow`, `block` | — | allow or block. Required when creating. |
| `description` | string | — | Free text shown in the firewall console. |
| `direction` | one of `inbound`, `outbound` | — | inbound or outbound. Required when creating. |
| `dry_run` | boolean | — | Report what would change without applying it. |
| `enabled` | boolean | — | Whether the rule applies. A DISABLED RULE STILL EXISTS — and a disabled Allow rule blocks traffic just as an enabled Block rule does, for a different reason. |
| `local_port` | string | — | Port or ports: "8451", "80,443", "8000-8100", or Any. |
| `name` | string | — | The rule's name (its DisplayName). Omit to LIST every rule. |
| `profile` | string | — | Profiles the rule applies in: Domain, Private, Public, Any (comma-separated). A RULE ENABLED ONLY IN Domain IS NOT IN EFFECT on a host whose network is classified Public — the commonest reason a port with a rule is still closed. Default Any. |
| `program` | string | — | Restrict to a program's full path. |
| `protocol` | string | — | TCP, UDP, ICMPv4, or Any. Default TCP when a port is given. |
| `remote_address` | string | — | Restrict to a remote address or CIDR, e.g. 10.32.0.0/16. |
| `state` | one of `present`, `absent` | — | Whether the rule should exist. Default present. |

### `windows_iis`

IIS sites, bindings and application pools. Without `name`: return every site (with its bindings, physical path, pool and state) and every application pool (with its state, .NET runtime, pipeline mode and identity). With `object` + `name`: ensure a site or an app pool is present/absent and started/stopped — a site takes `physical_path`, `bindings` ("http/*:8080:" or "https/*:443:host") and `app_pool`. Idempotent; `dry_run: true` returns the plan. web.config contents are NOT managed here — that is the config plane, which has codecs, generations and rollback.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `app_pool` | string | — | The application pool the site runs in. Created if missing. |
| `bindings` | array of string | — | Bindings as protocol/ip:port:hostname, e.g. ["http/*:8080:"]. Absent means bindings are not part of the declaration; given, they are enforced. |
| `dry_run` | boolean | — | Report what would change without applying it. |
| `managed_runtime` | string | — | For a pool: the .NET runtime version ("v4.0", or "" for No Managed Code). |
| `name` | string | — | The site or pool name. Omit to READ everything. |
| `object` | one of `site`, `app_pool` | — | What a write targets: site or app_pool. Required with `name`. |
| `physical_path` | string | — | The site's content folder. Required when creating a site. |
| `state` | one of `present`, `absent`, `started`, `stopped` | — | present/absent for existence, started/stopped for the running state (which implies present). Default present. |

## Read-only modules

### `getent`

Read the host's local accounts: `database: passwd` for users, `group` for groups. Windows local accounts presented in the passwd/group field layout the fleet's Accounts view reads — `uid` is the SID's relative identifier (built-ins below 1000, created accounts from 1001), and the full SID, enabled flag and last logon travel beside each record. Read-only; creating and removing accounts is the `user` / `group` module. Domain accounts are NOT in here: this is the local SAM, and asking a member server for the domain's users would be a different question with a different answer.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `database` | one of `passwd`, `group` | yes | passwd = local users, group = local groups with their members. |

### `package_facts`

Every program installed on this Windows host (name, version, arch, publisher, id), read from the Uninstall registry keys — the same list Programs and Features shows. Takes no parameters and always returns everything; filter client-side. The Windows counterpart of the Linux agent's dpkg/rpm package_facts, and the source of `facts.installed_packages` for a Windows host. NOTE that `name` is a DISPLAY NAME and not an installable id (use `id`, the ProductCode for MSI installs), and that Windows Server ROLES are not in here at all — those are `windows_feature`.

_Takes no parameters._

### `pending_reboot`

Whether this Windows host is waiting for a reboot, and WHY — the four independent places Windows records it (Component-Based Servicing, Windows Update, pending file renames, a pending computer rename), each reported separately plus the aggregate. Read-only, takes no parameters.

_Takes no parameters._

### `service_facts`

Every service registered with the Windows service control manager: name, display name, whether it is running, its start mode, its PID and the account it runs as. Takes no parameters and returns them all; filter client-side. The Windows counterpart of the Linux agent's systemd service_facts, with the same field names (unit/name/load/active/sub/enabled) so one Services view renders either host, plus Windows' own words (status, start_mode, pid, start_name) beside them. Read-only — starting and stopping is the `service` module.

_Takes no parameters._

### `storage_facts`

This Windows host's disks, partitions and volumes as a tree (disk → partition), with sizes in bytes, filesystem type and drive letter — the same block_devices shape the Linux agent's lsblk-based storage_facts returns, so one Storage view renders either host. LVM and VDO are reported as unavailable with the reason rather than omitted. Read-only; changing partitions is not this module.

_Takes no parameters._

### `windows_eventlog`

Read this Windows host's event log, filtered on the host. `logs` is a comma-separated list of channels (default "System,Application"; use windows_eventlog_channels to see which ones have records). `levels` is a comma-separated list of critical, error, warning, information, verbose, log_always — default "critical,error,warning", which is what "show me the problems" means and deliberately includes ERROR, the commonest of the three. `since` accepts a duration ("24h", "7d", "30m") or an ISO timestamp; `max_events` caps the reply (default 200); `provider`, `event_ids` and `contains` narrow further. Every event carries `level` (Windows' number, authoritative), `level_name` (ours, stable across languages) and `level_display` (what this host calls it — LOCALISED, and sometimes empty). Read-only: available even when the write gate is closed, because asking a host what went wrong must not require permission to change it.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `contains` | string | — | Only events whose message contains this text (matched on the host). |
| `event_ids` | string | — | Comma-separated event IDs. |
| `levels` | one of `log_always`, `critical`, `error`, `warning`, `information`, `verbose` | — | Comma-separated level names. Filtering happens by NUMBER on the host, because the display names are localised. |
| `logs` | string | — | Channels to read, comma-separated. 406 exist on a Server 2022; 83 have records. windows_eventlog_channels lists them with counts. |
| `max_events` | number | — | Cap on returned events. The reply says whether it was reached, so a truncated answer never looks complete. |
| `provider` | string | — | Only events from this provider (e.g. "SNMP", "Service Control Manager"). |
| `since` | string | — | A duration (24h, 7d, 30m) or an ISO timestamp. |

### `windows_eventlog_channels`

List this host's event log channels with their record counts, size and retention — the categories a human or an AI picks from before reading anything. 406 exist on a Server 2022 and 83 have records, so `only_with_records` defaults to true and the list is sorted by record count; pass false for the complete inventory. Read-only.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `name_like` | string | — | Only channels whose name matches this wildcard, e.g. "*PowerShell*". |
| `only_with_records` | boolean | — | Hide the channels that hold nothing (323 of 406 on a fresh Server 2022). |

### `windows_gpresult`

Report which Group Policy Objects apply to this host and which were denied, with the reason — the resultant set of policy, from `gpresult /X`. This system does NOT author or manage GPOs (Windows keeps that), but the RESULT is recorded as a foreign authority's intent: where a GPO and our own declared config touch the same setting, the GPO wins on the host and a convergence run would fight it forever. Returns applied GPOs (name, GUID, scope, link order, version), denied GPOs WITH the reason (access denied, security filtering, disabled link, empty), the scope of management, whether a slow link was detected, and when policy was last read. `scope` selects computer, user or both. Read-only: knowing which policy governs a host is not a change to it.

| Parameter | Type | Required | What it means |
|---|---|---|---|
| `include_xml` | boolean | — | Also return the raw gpresult XML (48 kB on a workgroup host, more in a domain). Off by default: the parsed summary is what a decision reads, and the extension sections are localised so nothing generic can be made of them here. |
| `scope` | one of `computer`, `user`, `both` | — | Computer policy is the one that governs a server. User policy applies to whoever is signed in, which on a server is usually nobody. |

