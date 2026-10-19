# Explainable diagnosis — why does it not work?

A host is asked **why** something does not work, and every sentence of the answer points at a measurement. The first
question it answers: *a service does not start* — on Windows and on Linux, with one contract.

Plan of record: [diagnosis-plan.md](diagnosis-plan.md). Contract: `configs/schemas/diagnosis.schema.json`. Rule
catalogue: `configs/diagnosis_rules.json`. Golden documents: `configs/schemas/diagnosis.examples/`. The one check of a
document: `bossman/bossman/services/diagnosis_contract.py`.

## The idea in four words: evidence, finding, remedy, timeline

**Evidence** is one measurement: what was read, through which interface, when the measured thing happened, one sentence
a person can read, and the raw data as it came. Its id is stable and says where it came from —
`scm:config:Spooler` (Windows service configuration), `evt:System:7038:20431` (an event record), `systemd:show:nginx.service`,
`journal:<cursor>`, `lsa:rights:<sid>` (the account rights of a SID), `authz:<sid>:<path>` (an access check),
`evt:Security:4625:<record>` (a failed service logon with its NTSTATUS). Ids are
unique within one diagnosis; an event record id repeats after a log is cleared, so a stored evidence is keyed by the
diagnosis and its id together.

**A finding** is a claim about a cause, made by a **rule**, with a **certainty**:

- *Proven* — measured directly: an exit code, a missing file, a right that is not granted.
- *Likely* — inferred from several measurements, or from log text.
- *Unknown* — the cause cannot be determined. The finding then says **what could not be measured** (its `gap`). Unknown
  is a named state, not an empty field.

A finding cites at least one evidence; a claim without evidence is not a finding. A target that is not running always
has at least one finding — when no rule matches, that finding is `svc.unexplained`, certainty Unknown, with its gap. So
there is no limbo between "explained" and "not looked at".

A finding may carry a **precedent**: the most recent change before the first failure — the service key was written, the
image was replaced, an update was installed — with the seconds in between. A precedent is a correlation, not a cause: it
never makes a finding Proven, and a finding whose only evidence is its precedent is refused.

Where the changes come from. Every change is recorded as evidence (so it is on the timeline) and offered as a
candidate; the precedent is the newest candidate at or before the failure (the exit time systemd reports, the newest
SCM failure event; when there is none, the moment of the diagnosis), within **7 days** — an older change stays on the
timeline but is not offered, because after a week nearly everything on a host has changed once. A change of the
**target** wins over a newer change of the **host**; the host's change is named only when the target did not change.

| | the target (and what it depends on) | the host |
|---|---|---|
| Linux | unit file and drop-ins, the program — by **inode change time** (`file:changed:`): dpkg and rpm keep the package's mtime, so an upgraded program's mtime is its build date; the package owning the unit or program and its last change (`pkg:dpkg.log:` / `pkg:rpm:`; an owner `dpkg.log` never mentions is stated with the date the log begins) | the newest other package install/upgrade/removal in `dpkg.log` (or rpm install time) |
| Windows | the service key's LastWriteTime and those of its dependencies (`reg:lastwrite:`), the image's later of creation and last write (`file:changed:` — a copied file keeps its old write time), events 7045 (installed) and 7040 (start type changed) | the newest MsiInstaller 1033–1036 or WindowsUpdateClient 19 — Defender's security-intelligence update (KB2267602) excluded, it installs several times a day |

rpm records no removals and does not tell an upgrade from an install; a host without dpkg or rpm is a named gap.

**A remedy** is a repair as data, never a script: what it addresses, the measured value now, the value it sets, how to
undo it, and how to tell it worked (the rule no longer fires, the service runs). Bossman turns it into an Ansible task,
a DSC configuration and a PowerShell suggestion and files it as a proposal; nothing executes it on its own.

**The timeline** lists every evidence that has a time, oldest first: what happened, and what changed before it.
**Gaps** list what the agent could not observe at all and why — so the absence of evidence is not read as evidence of
absence.

## Who decides what

- **The agents decide.** The Linux agent (Go, `service_diagnose`) and the Windows agent (C#, `service_diagnose`)
  collect the evidence through documented interfaces and apply the rules. The rules are plain functions over a
  collected snapshot, so they are tested on recorded snapshots without a live system.
- **Bossman checks again** when a document arrives, because an agent in the fleet may be older than Bossman. A document
  that breaks the contract is stored as such, with the reason; it is not dropped and not corrected. Bossman never raises
  a certainty. Where to ask: `POST /api/v1/agents/{id}/diagnose {"name": …}` (stores and returns the document),
  `GET /api/v1/agents/{id}/diagnoses` (the host's history, newest first), `GET /api/v1/diagnoses/{id}`; the MCP tools
  `diagnose_service(host, name)` and `recent_diagnoses(host, name)`, and the chat tool `diagnose_service`. An agent
  without the module answers with a named refusal (host, agent version), not an empty diagnosis.
- **Exports are made in Bossman only** (`services/diagnosis_export.py`, `GET /api/v1/diagnoses/{id}/export/{format}`,
  MCP `export_diagnosis`): `checkmk` (one `<<<local>>>` line: 0 running or stopped cleanly, 2 not running with a
  Proven/Likely cause, 3 Unknown or a document that does not hold), `gelf` (one message per finding and per evidence,
  joined by `_correlation_id`), `ansible` (FQCN: `ansible.windows.win_service` / `win_user_right` / `win_powershell`,
  `ansible.builtin.systemd_service` / `user`, apply and rollback playbooks, ansible-lint clean), `dsc` (DSC v3 — only
  the native `Microsoft.Windows/Service`, DSC ≥ 3.2; a user right or ACL has no native resource and is listed in
  `not_expressible`), `powershell` (apply and rollback for a person to read). An ACL repair removes the account's
  deny entries first — a deny wins over any allow — and its rollback restores the measured SDDL.
- **Sending the GELF export to a Graylog** (`POST /api/v1/diagnoses/{id}/export/gelf/send`, `services/gelf_send.py`):
  the same messages the `gelf` export produces, put on the wire over UDP (chunked to the GELF spec when a message is
  too large for one datagram) or TCP (NUL-terminated frames). Sending is **off** until `BOSSMAN_GELF_HOST` is set — the
  export is always available for inspection without it, and the send endpoint then 422s with the reason rather than
  dropping silently; a connection error is a 502 with its reason. Each message carries `_correlation_id` = the
  diagnosis id, `_kind` (finding or evidence), and for a finding its `_rule_id` and `_certainty`, so one diagnosis is
  one correlated group in Graylog. Its timestamp is the **measurement time** (the diagnosis' `collected_at`), not the
  send time — a finding from yesterday lands under yesterday, so search it by an absolute range, not "last hour". The
  dev stack ships a throwaway Graylog under the `graylog` compose profile (Graylog + its mandatory MongoDB + OpenSearch;
  `docker compose --profile graylog up -d`, web UI on `127.0.0.1:9000`, admin/admin) so `BOSSMAN_GELF_HOST=graylog`
  works out of the box. *Verified:* a real `windows-logon-right` diagnosis sent over UDP arrived as 6 messages
  (1 finding `svc.logon_right_missing` Proven + 5 evidence), every GELF field intact, confirmed through Graylog's own
  search API by correlation id.
- **A remedy becomes a proposal, never an action** (`POST /api/v1/diagnoses/{id}/propose {"finding": n}`, MCP
  `propose_remedy`): a change proposal of kind `remedy` whose preview holds the claim, certainty, the cited evidence,
  before/after/rollback/verify and the exports for that finding. The proposer cannot approve it (four-eyes — the
  proposal list says so per caller in `can_approve` / `cannot_approve_reason`, and the UI greys the button with
  that reason); approving records the second person and attaches the artifacts, and Bossman does not execute it.
  A finding without a remedy, or a diagnosis that does not hold, is refused with the reason.
- **Where a person sees it:** the Services snap-in of the management console (`/mmc`, Windows and Linux alike) has
  the row action "Why is it not running?" (`configs/mmc_snapins.json`, `view: "diagnosis"`). The panel shows the
  summary, each finding with its certainty badge (the word is the finding's own; the tooltip says what it means),
  the evidence behind it on demand, the precedent labelled a correlation, the gaps, the timeline, the repair with
  its undo and verification, the exports, "Propose this repair", and "Explain" with every unbacked sentence marked
  *not backed* and the reason. On an agent without the module the action is greyed with that reason before a click.
- **An AI only explains.** It may phrase a diagnosis for a person; each of its sentences must cite evidence ids, and a
  deterministic check marks every sentence it cannot back as *nicht belegt*. Certainty and gaps are written by code,
  word for word. `GET /api/v1/diagnoses/{id}/explain?language=de` (`services/diagnosis_explain.py`): the model answers
  structured `[{text, evidence_ids}]` (no prose splitting), thinking off and no token cap; a sentence is
  `backed: false`, with the reason, when it cites nothing, cites an id that is not in the diagnosis, states a
  certainty itself, or names a name, number, code or time that the cited evidence (fact, raw, time) does not contain.
  The `header` — each finding's certainty and claim, its precedent, its remedy, every gap — is code-written. Without
  a model the sentences come from a template over the findings, through the same check. A calling AI checks its own
  wording with the MCP tool `check_explanation`.

The image's Authenticode trust (WinVerifyTrust, including the security catalog that Windows system binaries are signed
through — not just an embedded signature) is attached to every Windows diagnosis as evidence, and a start that a policy
blocks is a finding of its own.

## The rules

One name per cause on every platform: a missing executable is `svc.image_missing` whether Windows logs event 7000 with
error 2 or systemd records status 203/EXEC. The catalogue says for each rule on which platforms it applies, the highest
certainty it may give, and on which evidence:

| Rule | Windows | Linux |
|---|---|---|
| `svc.not_installed` | OpenService: error 1060 | LoadState=not-found |
| `svc.disabled` | start type Disabled, error 1058 | unit masked |
| `svc.image_missing` | image file missing, 7000 with error 2/3 | ExecMainStatus=203 |
| `svc.image_path_unquoted` | ImagePath with a space, unquoted (Likely) | — |
| `svc.account_missing` | account does not resolve, error 1332 | ExecMainStatus=217, User= unknown |
| `svc.logon_failed` | 7038 / error 1069 with the account state that explains it, and Windows' own reason from the Security log — 4625, logon type 5 by services.exe, Status/SubStatus (0xC000006A wrong stored password, 0xC0000072 disabled, …), only the one belonging to the last start attempt | — |
| `svc.blocked_by_policy` | an enforcement block of the image — AppLocker event 8004 or Code Integrity / WDAC 3077 (the signature is attached as context) | — |
| `svc.deadlock` | Wait Chain Traversal reports a closed chain for a thread of the service's process (B14) — Windows only | — |
| `svc.logon_right_missing` | no SeServiceLogonRight (account or groups), or a deny right | — |
| `svc.access_denied` | AuthzAccessCheck denies execute/read on image or folder — the ACE named | status 243/238, EACCES on its paths |
| `svc.dependency_failed` | 7001/7003, a dependency not running — the first failed link | Result=dependency, a required unit failed |
| `svc.timeout` | 7009/7011, error 1053 | Result=timeout |
| `svc.crash` | 7031/7034 with an Application 1000/1026 of the image | core dump, SIGSEGV/ABRT/BUS |
| `svc.oom_killed` | — | Result=oom-kill |
| `svc.start_limit` | — | Result=start-limit-hit |
| `svc.condition_failed` | — | ConditionResult/AssertResult=no |
| `svc.exits_immediately` | 7023/7024/7034 with the service's own exit code | Result=exit-code, own exit status |
| `svc.config_invalid`, `svc.config_incomplete`, `svc.peer_unreachable`, `svc.network_unavailable`, `svc.not_initialized`, `svc.device_missing`, `svc.container_limit` | — | journal text (Likely) |
| `svc.recent_incident` | the agent's incident ring holds a recent crash, abnormal exit or .NET exception for the service's image (ETW) — **Likely** | an OOM kill or a fatal signal (SEGV/ABRT/KILL/QUIT) for the process (eBPF) — **Likely** |
| `svc.stopped_cleanly` | stopped, exit code 0, stop recorded / manual and never started | inactive, Result=success (incl. a finished oneshot) |
| `svc.unexplained` | no rule matched (Unknown, with the gap) | same |

Windows events are matched on their id and their structured data, never on message text — the host may speak German —
and the SCM names a service in its events by its **display name**, which is localized; the agent matches that against
the display name it read from the service configuration.

### The incident ring — a past incident, not just the present state

Most of the rules read the *current* state. A transient failure — a service that crashed at 03:00 and restarted, a
hang that cleared, a `.NET` exception just before it exited — is gone by the time anyone asks. So the agent keeps a
**bounded, in-memory incident ring** of recent past events and the diagnosis looks back on it as `svc.recent_incident`.
On Windows a persistent real-time **ETW** session fills it (the kernel Process provider for an abnormal exit or a
crash, the CLR provider for a thrown exception); on Linux the agent's existing **eBPF** collector already records OOM
kills and fatal signals, and the diagnosis reads those. A `svc.recent_incident` finding is always **Likely** — it
describes a *past* invocation, never the present state, so the certainty is never raised — and it cites each incident as
evidence, matched to the service by its image (the kernel comm on Linux). It is **metadata only** — time, pid, image,
exit code or exception type — never a payload, memory or dump, so it is privacy-safe by construction, and a clean exit
(or a normal `SIGTERM`/`SIGINT` stop) is not an incident. On Windows the ring is flushed to a small, size-capped file in
the agent's state dir so it survives a reboot; on Linux it is **read-only on the metrics store** — the incidents live
in the collector's in-memory ring and surface only on demand inside a diagnosis, adding no time-series.

## Limits, said up front

- Only documented interfaces: the service control manager, the event log, LSA, Authz, WinVerifyTrust on Windows;
  systemctl, the journal and the file system on Linux. Windows is not decompiled. What these interfaces cannot show is
  reported as a gap — "not measurable with public interfaces" — never guessed.
- A domain account's groups cannot be resolved without the domain controller; managed and virtual service accounts need
  their own handling. Until then their rights and access checks are Unknown, with that reason.
- On Linux the journal of the current invocation is read, not a log file the daemon writes itself (svxlink logs its
  reason only to `--logfile`); such a cause stays `svc.exits_immediately` without its reason. A role that firewalls
  or reconfigures the host's network (ferm, connman) can lock the agent itself out — no diagnosis is then possible
  from outside, and the request says it could not reach the host.
- A Windows service whose start hangs stays START_PENDING without any event; the finding is `svc.timeout` Likely,
  measured by the time it has been pending past the SCM's 30 s timeout without reporting progress.
  Its wait chains (Wait Chain Traversal — no memory is read) are evidence; a chain Windows reports as a cycle is
  `svc.deadlock` Proven. The chain sees native waits (kernel mutexes, critical sections, ALPC, COM, thread and process
  waits) but not a .NET program waiting through `Mutex.WaitOne` (measured: those threads show as Blocked on nothing) —
  such a hang stays `svc.timeout` Likely. When the chain shows threads blocked with no lock owner and the
  process is .NET (detected by its `dotnet-diagnostic-<pid>` pipe), that managed blind spot is said as a gap rather
  than left as an empty chain.
- A systemd unit that has been activating for more than 30 s is `svc.timeout` Likely with what its threads are doing,
  read from `/proc/<MainPID>/task/*` (state letter and kernel wait channel) — no debugger, no memory.
- Where a Linux service crashed is resolved without a core dump: the kernel's own fault line (dmesg / journalctl -k)
  gives the module and instruction pointer, and the function comes from the module's symbols — a local debug file, else
  debuginfod by build id, else the module's own or exported symbol table (the last named as such). A module updated
  since, or no symbols, is a named gap.
- Where a Windows service crashed is resolved without a memory dump: module and offset from event 1000, the module's
  PDB from Microsoft's public symbol server (the agent fetches it; dbghelp in System32 has no symsrv), the function
  through dbghelp; for .NET the exception and first managed frame from event 1026. If the module was updated since the
  crash, its symbols would name other code — that is a gap, not a guess. A module without public symbols (a
  third-party program) stays module + offset.
- Windows Update's list is only complete when its search ends `Succeeded`: right after a reboot it answers
  `SucceededWithErrors` with an empty list for a few minutes (measured). The agent says so (`complete: false`), and
  Bossman keeps a Windows host's last complete CVE state instead of replacing it with that.
- The diagnosis explains the present state and the recent history the logs still hold. A failure whose traces have
  rolled out of the logs is Unknown; a permanently recording agent (ETW, journal ring) is a later step.
