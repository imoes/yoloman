"""A diagnosis in the formats other tools read (plan B9) — produced HERE only, never a second time in the agents.

- `checkmk`:    one `<<<local>>>` line — the service's state with the cause as its text.
- `gelf`:       one GELF 1.1 message per finding and per evidence, joined by `_correlation_id` = diagnosis_id.
- `ansible`:    the remedies as a playbook (FQCN modules), and the rollback as a second one.
- `dsc`:        a DSC v3 configuration document — only what a NATIVE resource expresses (Microsoft.Windows/Service,
                DSC ≥ 3.2); a user right or an ACL has no native resource and is named, not faked.
- `powershell`: the remedies as a script for a person to read and run, and its rollback.

Every exporter returns what it could NOT express in `not_expressible`, each with its reason: a remedy that silently
drops out of an export would look like "nothing to repair". Nothing here runs anything; B10 files the result as a
proposal.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import yaml

FORMATS = ("checkmk", "gelf", "ansible", "dsc", "powershell")

# The SCM's start types (what the Windows agent reports) in each target's own words.
_ANSIBLE_START = {"auto": "auto", "delayed": "delayed", "demand": "manual", "disabled": "disabled"}
_DSC_START = {"auto": "Automatic", "delayed": "AutomaticDelayedStart", "demand": "Manual", "disabled": "Disabled"}
_SC_START = {"auto": "auto", "delayed": "delayed-auto", "demand": "demand", "disabled": "disabled"}
# Windows' FileSystemRights for what the access check asked (AccountCollector: file → execute+read, folder → traverse+list).
_FS_RIGHTS = {"execute+read": "ReadAndExecute", "traverse+list": "ReadAndExecute"}

# LsaAddAccountRights / LsaRemoveAccountRights — no built-in cmdlet exists for user rights. The same code the Windows
# probe runs on bossman-wintest (tools/diagnosis_probe_windows.py), so it is the tested form.
_LSA = r"""if (-not ('YLsa' -as [type])) { Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Security.Principal;
public static class YLsa {
  [StructLayout(LayoutKind.Sequential)] struct U { public ushort L; public ushort M; public IntPtr B; }
  [StructLayout(LayoutKind.Sequential)] struct OA { public int Len; public IntPtr R; public IntPtr N; public int A; public IntPtr SD; public IntPtr Q; }
  [DllImport("advapi32")] static extern uint LsaOpenPolicy(IntPtr s, ref OA oa, int access, out IntPtr h);
  [DllImport("advapi32")] static extern uint LsaAddAccountRights(IntPtr h, byte[] sid, U[] r, int n);
  [DllImport("advapi32")] static extern uint LsaRemoveAccountRights(IntPtr h, byte[] sid, bool all, U[] r, int n);
  [DllImport("advapi32")] static extern uint LsaClose(IntPtr h);
  public static uint Set(string acct, string right, bool grant) {
    if (acct.StartsWith(".\\")) acct = Environment.MachineName + acct.Substring(1);
    var sid = (SecurityIdentifier)new NTAccount(acct).Translate(typeof(SecurityIdentifier));
    var b = new byte[sid.BinaryLength]; sid.GetBinaryForm(b, 0);
    var oa = new OA(); IntPtr h; uint st = LsaOpenPolicy(IntPtr.Zero, ref oa, 0x810, out h); if (st != 0) return st;
    var u = new U { L = (ushort)(right.Length * 2), M = (ushort)(right.Length * 2 + 2), B = Marshal.StringToHGlobalUni(right) };
    st = grant ? LsaAddAccountRights(h, b, new[] { u }, 1) : LsaRemoveAccountRights(h, b, false, new[] { u }, 1);
    Marshal.FreeHGlobal(u.B); LsaClose(h); return st;
  }
}
'@ }"""


class _IndentedDumper(yaml.SafeDumper):
    """Lists indented under their key — the layout yamllint (and so ansible-lint) requires."""

    def increase_indent(self, flow: bool = False, indentless: bool = False):
        return super().increase_indent(flow, False)


def _str_block(dumper: yaml.SafeDumper, value: str):
    # a script stays a readable block (`|`) instead of one escaped line
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style="|" if "\n" in value else None)


_IndentedDumper.add_representer(str, _str_block)


def _remedies(doc: dict) -> list[tuple[dict, dict]]:
    return [(f, f["remedy"]) for f in doc.get("findings") or [] if f.get("remedy")]


def _ps_quote(s: str) -> str:
    return "'" + str(s).replace("'", "''") + "'"


def _one_line(s: str) -> str:
    return " ".join(str(s).split())


def _ts(value: str | None) -> float:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return datetime.now(timezone.utc).timestamp()


# --- Checkmk -------------------------------------------------------------------------------------------------------

def checkmk(doc: dict, contract_violations: list[str] | None = None) -> dict[str, Any]:
    """`<state> "Diagnosis <target>" findings=<n> <text>` — 0 running or stopped cleanly, 2 not running with a Proven
    or Likely cause, 3 when the cause is Unknown or the document does not hold (Checkmk's UNKNOWN is that state)."""
    name = doc.get("target", {}).get("name", "?")
    findings = doc.get("findings") or []
    lead = findings[0] if findings else None
    if contract_violations:
        state, text = 3, "the diagnosis does not hold: " + "; ".join(contract_violations[:3])
    elif lead is None or lead["rule_id"] == "svc.stopped_cleanly":
        state, text = 0, doc.get("summary") or doc.get("status", "")
    else:
        state = 3 if lead["certainty"] == "Unknown" else 2
        text = f"{lead['claim']} [{lead['rule_id']}, {lead['certainty']}; evidence {', '.join(lead['evidence_ids'])}]"
        if lead.get("gap"):
            text += f" — not measurable: {lead['gap']}"
    line = f'{state} "Diagnosis {name}" findings={len(findings)} {_one_line(text)}'
    return {"format": "checkmk", "content": "<<<local>>>\n" + line + "\n", "not_expressible": []}


# --- GELF ----------------------------------------------------------------------------------------------------------

_GELF_LEVEL = {"Proven": 3, "Likely": 4, "Unknown": 5}   # syslog: error, warning, notice; evidence is 6 (info)


def gelf(doc: dict) -> dict[str, Any]:
    base = {"version": "1.1", "host": doc.get("host", ""), "_correlation_id": doc["diagnosis_id"],
            "_diagnosis_id": doc["diagnosis_id"], "_target": doc.get("target", {}).get("name", ""),
            "_platform": doc.get("platform", "")}
    out = []
    for f in doc.get("findings") or []:
        full = f["claim"]
        if f.get("precedent"):
            p = f["precedent"]
            full += f"\nPreceded {p['gap_seconds']} s earlier by: {p['change']} ({p['evidence_id']}) — a correlation, not a cause."
        if f.get("gap"):
            full += f"\nNot measurable: {f['gap']}"
        out.append({**base, "short_message": _one_line(f["claim"])[:250], "full_message": full,
                    "timestamp": _ts(doc.get("collected_at")), "level": _GELF_LEVEL.get(f["certainty"], 5),
                    "_kind": "finding", "_rule_id": f["rule_id"], "_certainty": f["certainty"],
                    "_evidence_ids": ",".join(f["evidence_ids"])})
    for e in doc.get("evidence") or []:
        out.append({**base, "short_message": _one_line(e["fact"])[:250], "full_message": e["fact"],
                    "timestamp": _ts(e.get("observed") or doc.get("collected_at")), "level": 6,
                    "_kind": "evidence", "_evidence_id": e["id"], "_source": e["source"]})
    return {"format": "gelf", "content": out, "not_expressible": []}


# --- Ansible -------------------------------------------------------------------------------------------------------

def _cmd_task(name: str, cmd: str) -> dict:
    """One imperative step as an Ansible task: shell only when the command actually needs a shell (a pipe, `&&`, a
    redirect), command otherwise — ansible-lint's command-vs-shell rule. changed_when is explicit because these are
    one-shot operations (snapshot, upgrade, restore), not idempotent state the module can judge."""
    module = "ansible.builtin.shell" if any(c in cmd for c in "&|;<>") else "ansible.builtin.command"
    return {"name": name, module: {"cmd": cmd}, "changed_when": True}


def _ansible_tasks(doc: dict, f: dict, r: dict, rollback: bool) -> tuple[list[dict], str | None]:
    kind, tid, attr, plat = r["target"]["kind"], r["target"]["id"], r["target"].get("attribute"), doc["platform"]
    rb = r["rollback"]
    tag = f"{f['rule_id']}: {tid}"
    if kind == "package":
        # The update remedy (plan U4): snapshot the root volume, then install; the rollback restores the snapshot. The
        # agent put the exact commands in the remedy (the snapshot, install and restore vary by LVM/ZFS and apt/dnf).
        rv = rb.get("value") if isinstance(rb.get("value"), dict) else {}
        if rollback:
            cmd = (rv or {}).get("command")
            if not cmd:
                return [], f"{tag}: the update rollback carries no restore command"
            return [_cmd_task(f"Roll back the update by restoring the snapshot ({f['rule_id']})", cmd)], None
        before, after = r.get("before") or {}, r.get("after") or {}
        tasks: list[dict] = []
        if before.get("snapshot_command"):
            tasks.append(_cmd_task(f"Snapshot {before.get('volume')} before updating ({f['rule_id']})", before["snapshot_command"]))
        if after.get("install_command"):
            tasks.append(_cmd_task(f"Install the pending updates ({f['rule_id']})", after["install_command"]))
        if not tasks:
            return [], f"{tag}: the update remedy carries no commands"
        return tasks, None
    if kind == "service_start_type" and plat == "windows":
        val = rb["value"] if rollback else r["after"]
        return [{"name": f"Set the start type of {tid} to {val} ({tag})",
                 "ansible.windows.win_service": {"name": tid, "start_mode": _ANSIBLE_START.get(val, val)}}], None
    if kind == "user_right" and plat == "windows":
        right, _, account = tid.partition("@")
        return [{"name": f"{'Revoke' if rollback else 'Grant'} {right} for {account} ({f['rule_id']})",
                 "ansible.windows.win_user_right": {"name": right, "users": [account],
                                                    "action": "remove" if rollback else "add"}}], None
    if kind == "file_acl" and plat == "windows":
        script = _ps_acl(tid, attr or "", r, rollback)
        return [{"name": f"{'Restore the ACL of' if rollback else 'Let ' + str(attr) + ' read and execute'} {tid} ({f['rule_id']})",
                 "ansible.windows.win_powershell": {"script": script}}], None
    if kind == "systemd_unit" and plat == "linux" and attr == "masked":
        masked = bool(rb["value"] if rollback else r["after"])
        return [{"name": f"{'Mask' if masked else 'Unmask'} {tid} ({f['rule_id']})",
                 "ansible.builtin.systemd_service": {"name": tid, "masked": masked}}], None
    if kind == "service_account" and plat == "linux":
        if rollback:
            return [{"name": f"Remove the account {tid} again ({f['rule_id']})",
                     "ansible.builtin.user": {"name": tid, "state": "absent"}}], None
        return [{"name": f"Create the system account {tid} ({f['rule_id']})",
                 "ansible.builtin.user": {"name": tid, "system": True, "create_home": False,
                                          "shell": "/usr/sbin/nologin"}}], None
    return [], f"{tag}: no Ansible mapping for remedy kind {kind} on {plat} yet"


def ansible(doc: dict) -> dict[str, Any]:
    apply, back, missing = [], [], []
    for f, r in _remedies(doc):
        t, why = _ansible_tasks(doc, f, r, rollback=False)
        if why:
            missing.append(why)
            continue
        apply += t
        back += _ansible_tasks(doc, f, r, rollback=True)[0]
    name = doc.get("target", {}).get("name", "?")

    def play(title: str, tasks: list[dict]) -> str | None:
        if not tasks:
            return None
        return "---\n" + yaml.dump([{"name": title, "hosts": doc.get("host", "all"), "gather_facts": False,
                                     "tasks": tasks}], Dumper=_IndentedDumper, sort_keys=False, allow_unicode=True,
                                    width=200)

    return {"format": "ansible", "apply": play(f"Repair {name} (diagnosis {doc['diagnosis_id']})", apply),
            "rollback": play(f"Roll back the repair of {name} (diagnosis {doc['diagnosis_id']})", back),
            "not_expressible": missing}


# --- DSC v3 --------------------------------------------------------------------------------------------------------

DSC_SCHEMA = "https://aka.ms/dsc/schemas/v3/bundled/config/document.json"


def dsc(doc: dict) -> dict[str, Any]:
    if doc.get("platform") != "windows":
        return {"format": "dsc", "apply": None, "rollback": None,
                "not_expressible": ["DSC is exported for Windows targets; use the Ansible export for Linux"]}
    apply, back, missing = [], [], []
    for f, r in _remedies(doc):
        kind, tid = r["target"]["kind"], r["target"]["id"]
        if kind == "service_start_type":
            for target, val in ((apply, r["after"]), (back, r["rollback"]["value"])):
                target.append({"name": f"{tid} start type", "type": "Microsoft.Windows/Service",
                               "properties": {"name": tid, "startType": _DSC_START.get(val, val)}})
        else:
            missing.append(f"{f['rule_id']}: {tid}: DSC v3 has no native resource for {kind} — "
                           "use the PowerShell or Ansible export")

    def document(res: list[dict]) -> str | None:
        return yaml.safe_dump({"$schema": DSC_SCHEMA, "resources": res}, sort_keys=False) if res else None

    return {"format": "dsc", "apply": document(apply), "rollback": document(back), "not_expressible": missing}


# --- PowerShell ----------------------------------------------------------------------------------------------------

def _ps_acl(path: str, account: str, r: dict, rollback: bool) -> str:
    if rollback:
        sddl = (r.get("before") or {}).get("sddl") if isinstance(r.get("before"), dict) else None
        return (f"$acl = Get-Acl -LiteralPath {_ps_quote(path)}\n"
                f"$acl.SetSecurityDescriptorSddlForm({_ps_quote(sddl or '')})\n"
                f"Set-Acl -LiteralPath {_ps_quote(path)} -AclObject $acl")
    want = (r.get("after") or {}).get("grant", "execute+read") if isinstance(r.get("after"), dict) else "execute+read"
    rights = _FS_RIGHTS.get(want, "ReadAndExecute")
    # A deny entry wins over any allow, so the account's deny entries go first; then the allow entry.
    return (f"$path = {_ps_quote(path)}\n"
            f"$name = {_ps_quote(account)}\n"
            # NTAccount does not read ".\\user" (measured on bossman-wintest): the dot is this computer's name.
            "if ($name.StartsWith('.\\')) { $name = $env:COMPUTERNAME + $name.Substring(1) }\n"
            "$who = New-Object System.Security.Principal.NTAccount($name)\n"
            "$acl = Get-Acl -LiteralPath $path\n"
            "$sid = $who.Translate([System.Security.Principal.SecurityIdentifier])\n"
            "$acl.Access |\n"
            "    Where-Object { $_.AccessControlType -eq 'Deny' -and\n"
            "                   $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $sid } |\n"
            "    ForEach-Object { [void]$acl.RemoveAccessRuleSpecific($_) }\n"
            f"$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($who, '{rights}', 'Allow')))\n"
            "Set-Acl -LiteralPath $path -AclObject $acl")


def _ps_block(doc: dict, f: dict, r: dict, rollback: bool) -> tuple[str | None, str | None]:
    kind, tid, attr = r["target"]["kind"], r["target"]["id"], r["target"].get("attribute")
    if kind == "service_start_type":
        val = r["rollback"]["value"] if rollback else r["after"]
        return f"sc.exe config {_ps_quote(tid)} start= {_SC_START.get(val, val)}", None
    if kind == "user_right":
        right, _, account = tid.partition("@")
        return (_LSA + f"\n$st = [YLsa]::Set({_ps_quote(account)}, {_ps_quote(right)}, ${'false' if rollback else 'true'})\n"
                f"if ($st -ne 0) {{ throw \"LSA returned NTSTATUS $st\" }}"), None
    if kind == "file_acl":
        return _ps_acl(tid, attr or "", r, rollback), None
    return None, f"{f['rule_id']}: {tid}: no PowerShell form for remedy kind {kind} yet"


def powershell(doc: dict) -> dict[str, Any]:
    if doc.get("platform") != "windows":
        return {"format": "powershell", "apply": None, "rollback": None,
                "not_expressible": ["the PowerShell suggestion is for Windows targets; use the Ansible export for Linux"]}
    apply, back, missing = [], [], []
    for f, r in _remedies(doc):
        a, why = _ps_block(doc, f, r, rollback=False)
        if why:
            missing.append(why)
            continue
        head = f"# {f['rule_id']} ({f['certainty']}): {_one_line(f['claim'])}"
        apply.append(f"{head}\n{a}")
        back.append(f"# undo: {f['rule_id']}\n{_ps_block(doc, f, r, rollback=True)[0]}")
    intro = (f"# Suggested by the diagnosis {doc['diagnosis_id']} of {doc.get('target', {}).get('name')} on "
             f"{doc.get('host')}. Read before running; run elevated.\n$ErrorActionPreference = 'Stop'\n\n")
    return {"format": "powershell", "apply": intro + "\n\n".join(apply) if apply else None,
            "rollback": intro + "\n\n".join(back) if back else None, "not_expressible": missing}


def export(doc: dict, fmt: str, contract_violations: list[str] | None = None) -> dict[str, Any]:
    if fmt == "checkmk":
        return checkmk(doc, contract_violations)
    if fmt not in FORMATS:
        raise ValueError(f"unknown export format {fmt!r} — one of {', '.join(FORMATS)}")
    out = {"gelf": gelf, "ansible": ansible, "dsc": dsc, "powershell": powershell}[fmt](doc)
    if fmt != "gelf" and not _remedies(doc):
        out["note"] = "no finding of this diagnosis offers a remedy, so there is nothing to export"
    return out
