"""Break Windows services on purpose and check that `service_diagnose` names the cause — on a real Windows host.

    .venv-host/bin/python -m bossman.tools.diagnosis_probe_windows [--host bossman-wintest] [--only case,case] [--keep]

The Windows twin of diagnosis_probe_linux: through Bossman's tool API only, the agent's `powershell` module creates
`yoloman-probe-*` services with sc.exe, each broken in one known way, tries to start them (so the service control
manager records what happened), then `service_diagnose` is asked and its leading finding compared with the
expectation; every document is checked against the contract (services/diagnosis_contract.py). Everything the probe
creates is deleted afterwards (services, the probe account), unless --keep. Results: configs/diagnosis_probe_windows.json.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import subprocess
import tempfile
import time
from pathlib import Path

from bossman.services import diagnosis_contract as C
from bossman.tools import qualify_packages as Q
from bossman.tools.deploy_windows_agent import AGENT, LAN_IP, agent_id, bossman, ps, serve

OUT = Q._CONFIGS / "diagnosis_probe_windows.json"
PW = "Pr0be!" + secrets.token_hex(6)

# LsaAddAccountRights / LsaRemoveAccountRights from PowerShell: there is no built-in cmdlet for user rights, and
# secedit round-trips the whole local policy. YLsa.Set(account, right, grant) returns the NTSTATUS (0 = done).
LSA = r"""
if (-not ('YLsa' -as [type])) { Add-Type -TypeDefinition @'
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
    st = grant ? LsaAddAccountRights(h, b, new[] { u }, 1) : LsaRemoveAccountRights(h, b, true, null, 0);
    Marshal.FreeHGlobal(u.B); LsaClose(h); return st;
  }
}
'@ }
"""


def as_user(svc: str, user: str) -> str:
    """Set the service's account through ChangeServiceConfig (WMI Change()), which grants no right on its own."""
    return (f"$s = Get-CimInstance Win32_Service -Filter \"Name='{svc}'\"; "
            f"Invoke-CimMethod -InputObject $s -MethodName Change -Arguments @{{StartName='.\\{user}'; StartPassword='{PW}'}} | Out-Null")


def user_with_right(user: str) -> str:
    return (f"net user {user} '{PW}' /add /y | Out-Null; " + LSA
            + f"$st = [YLsa]::Set('.\\{user}', 'SeServiceLogonRight', $true); if ($st -ne 0) {{ throw \"LsaAddAccountRights: $st\" }}; ")


# (case, service name, PowerShell that creates the broken setup, expected leading "rule/certainty")
CASES: list[tuple[str, str, str, str]] = [
    ("image-missing", "yoloman-probe-img",
     r'sc.exe create yoloman-probe-img binPath= "C:\yoloman-probe\missing.exe" start= demand DisplayName= "yoloman probe (image)"',
     "svc.image_missing/Proven"),
    ("unquoted-path", "yoloman-probe-unq",
     r'sc.exe create yoloman-probe-unq binPath= "C:\yoloman probe\dir x\missing.exe" start= demand',
     "svc.image_missing/Proven"),
    ("disabled", "yoloman-probe-dis",
     r'sc.exe create yoloman-probe-dis binPath= "C:\Windows\System32\cmd.exe" start= disabled',
     "svc.disabled/Proven"),
    ("dependency", "yoloman-probe-dep",
     r'sc.exe create yoloman-probe-base binPath= "C:\Windows\System32\cmd.exe" start= disabled DisplayName= "yoloman probe (base)"; '
     r'sc.exe create yoloman-probe-dep binPath= "C:\Windows\System32\cmd.exe" start= demand depend= yoloman-probe-base DisplayName= "yoloman probe (dependency)"',
     "svc.dependency_failed/Proven"),
    ("timeout", "yoloman-probe-to",
     r'sc.exe create yoloman-probe-to binPath= "C:\Windows\System32\cmd.exe /c ping -n 120 127.0.0.1" start= demand',
     "svc.timeout/Proven"),
    ("logon-right", "yoloman-probe-logon",
     # a fresh local account WITHOUT SeServiceLogonRight, set through ChangeServiceConfig (WMI Change()), which —
     # unlike the Services console — does not grant the right on its own.
     "net user yoloman-probeuser '" + PW + "' /add /y | Out-Null; "
     r'sc.exe create yoloman-probe-logon binPath= "C:\Windows\System32\cmd.exe" start= demand; '
     "$s = Get-CimInstance Win32_Service -Filter \"Name='yoloman-probe-logon'\"; "
     "Invoke-CimMethod -InputObject $s -MethodName Change -Arguments @{StartName='.\\yoloman-probeuser'; StartPassword='" + PW + "'} | Out-Null",
     "svc.logon_right_missing/Proven"),
    ("logon-right-lsa", "yoloman-probe-lsa",
     # the same account, but NO start: the missing right is read from LSA before anything fails
     "net user yoloman-probeuser '" + PW + "' /add /y 2>$null | Out-Null; "
     r'sc.exe create yoloman-probe-lsa binPath= "C:\Windows\System32\cmd.exe" start= demand; ' + as_user("yoloman-probe-lsa", "yoloman-probeuser"),
     "svc.logon_right_missing/Proven"),
    ("account-disabled", "yoloman-probe-acdis",
     user_with_right("yoloman-probeok")
     + r'sc.exe create yoloman-probe-acdis binPath= "C:\Windows\System32\cmd.exe" start= demand; ' + as_user("yoloman-probe-acdis", "yoloman-probeok")
     + "; net user yoloman-probeok /active:no | Out-Null",
     "svc.logon_failed/Proven"),
    ("wrong-password", "yoloman-probe-pw",
     # the account exists, may log on as a service — but the password stored for the service is wrong: only the
     # Security log's 4625 (SubStatus 0xC000006A) proves that
     user_with_right("yoloman-probepw")
     + r'sc.exe create yoloman-probe-pw binPath= "C:\Windows\System32\cmd.exe" start= demand; '
     + "$s = Get-CimInstance Win32_Service -Filter \"Name='yoloman-probe-pw'\"; "
     + "Invoke-CimMethod -InputObject $s -MethodName Change -Arguments @{StartName='.\\yoloman-probepw'; StartPassword='not-the-password'} | Out-Null",
     "svc.logon_failed/Proven"),
    ("account-gone", "yoloman-probe-gone",
     # set a real account, then delete it: the service keeps a name that no longer resolves to a SID
     user_with_right("yoloman-probegone")
     + r'sc.exe create yoloman-probe-gone binPath= "C:\Windows\System32\cmd.exe" start= demand; ' + as_user("yoloman-probe-gone", "yoloman-probegone")
     + "; [void][YLsa]::Set('.\\yoloman-probegone', 'SeServiceLogonRight', $false); net user yoloman-probegone /delete | Out-Null",
     "svc.account_missing/Proven"),
    ("access-denied", "yoloman-probe-acl",
     # a real executable the account may not run: an explicit deny ACE for it on the image
     user_with_right("yoloman-probeacl")
     + r"New-Item -ItemType Directory -Force C:\yoloman-probe-acl | Out-Null; Copy-Item C:\Windows\System32\cmd.exe C:\yoloman-probe-acl\probe.exe -Force; "
     + r"icacls C:\yoloman-probe-acl\probe.exe /deny 'yoloman-probeacl:(RX)' | Out-Null; "
     + r'sc.exe create yoloman-probe-acl binPath= "C:\yoloman-probe-acl\probe.exe" start= demand; ' + as_user("yoloman-probe-acl", "yoloman-probeacl"),
     "svc.access_denied/Proven"),
    ("precedent-change", "yoloman-probe-chg",
     # change, then break: created startable, disabled 3 s later — the change must be named as the precedent
     r'sc.exe create yoloman-probe-chg binPath= "C:\Windows\System32\cmd.exe" start= demand DisplayName= "yoloman probe (change)"; '
     "Start-Sleep -Seconds 3; sc.exe config yoloman-probe-chg start= disabled | Out-Null",
     "svc.disabled/Proven"),
    # the probe service (windows-agent/AgenticMcp.Agent.ProbeService, staged by stage_probe_service): failures cmd.exe
    # cannot produce — its own exit code, a crash after RUNNING, a hang in OnStart
    ("exit-specific", "yoloman-probe-xs",
     r'sc.exe create yoloman-probe-xs binPath= "C:\yoloman-probe-svc\ProbeService.exe --mode=exit-specific:42" start= demand',
     "svc.exits_immediately/Proven"),
    ("crash", "yoloman-probe-crash",
     r'sc.exe create yoloman-probe-crash binPath= "C:\yoloman-probe-svc\ProbeService.exe --mode=crash" start= demand',
     "svc.crash/Proven"),
    ("hang", "yoloman-probe-hang",
     r'sc.exe create yoloman-probe-hang binPath= "C:\yoloman-probe-svc\ProbeService.exe --mode=hang" start= demand',
     # Likely, not Proven: the SCM records no event for a start that never ends — only the time is measured
     "svc.timeout/Likely"),
    ("deadlock", "yoloman-probe-dl",
     r'sc.exe create yoloman-probe-dl binPath= "C:\yoloman-probe-svc\ProbeService.exe --mode=deadlock" start= demand',
     # B14: two threads holding one kernel mutex each and waiting for the other's — Wait Chain Traversal's cycle
     "svc.deadlock/Proven"),
    ("not-installed", "yoloman-probe-nosuch", "", "svc.not_installed/Proven"),
    ("never-started", "yoloman-probe-idle",
     r'sc.exe create yoloman-probe-idle binPath= "C:\Windows\System32\cmd.exe" start= demand',
     "svc.stopped_cleanly/Proven"),
    ("running", "EventLog", "", "running"),
]

NO_START = {"not-installed", "never-started", "running", "logon-right-lsa", "account-gone"}
CLEANUP = ("Get-CimInstance Win32_Service -Filter \"Name LIKE 'yoloman-probe-%' AND State='Start Pending'\" | "
           "ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; "
           "foreach ($n in 'yoloman-probe-img','yoloman-probe-unq','yoloman-probe-dis','yoloman-probe-dep','yoloman-probe-base',"
           "'yoloman-probe-to','yoloman-probe-logon','yoloman-probe-idle','yoloman-probe-lsa','yoloman-probe-acdis',"
           "'yoloman-probe-gone','yoloman-probe-acl','yoloman-probe-chg','yoloman-probe-xs','yoloman-probe-crash',"
           "'yoloman-probe-hang','yoloman-probe-pw','yoloman-probe-dl') { sc.exe stop $n 2>$null | Out-Null; sc.exe delete $n 2>$null | Out-Null }; "
           + LSA +
           # the right goes with the account (LsaRemoveAccountRights, all) so no orphaned SID stays in the local policy
           "foreach ($u in 'yoloman-probeuser','yoloman-probeok','yoloman-probegone','yoloman-probeacl','yoloman-probepw') { "
           "try { [void][YLsa]::Set('.\\' + $u, 'SeServiceLogonRight', $false) } catch {}; net user $u /delete 2>$null | Out-Null }; "
           "if (Test-Path C:\\yoloman-probe-acl) { icacls C:\\yoloman-probe-acl /reset /T | Out-Null; Remove-Item -Recurse -Force C:\\yoloman-probe-acl }; "
           "Start-Sleep -Seconds 2; if (Test-Path C:\\yoloman-probe-svc) { Remove-Item -Recurse -Force C:\\yoloman-probe-svc -ErrorAction SilentlyContinue }; 'cleaned'")


PROBE_SERVICE_CASES = {"exit-specific", "crash", "hang", "deadlock"}


def stage_probe_service(c, aid: str, port: int = 18781) -> None:
    """Build the probe service and let the host fetch it to C:\\yoloman-probe-svc — the same way the agent itself is
    rolled out (tools/deploy_windows_agent.py): no SMB, no WinRM, the agent's own powershell module downloads it."""
    with tempfile.TemporaryDirectory() as tmp:
        env = {**os.environ, "PATH": f"{Path.home()}/.dotnet:{os.environ['PATH']}", "DOTNET_CLI_TELEMETRY_OPTOUT": "1"}
        subprocess.run([f"{Path.home()}/.dotnet/dotnet", "publish", str(AGENT / "AgenticMcp.Agent.ProbeService"), "-c", "Release",
                        "-o", tmp], check=True, env=env, stdout=subprocess.DEVNULL)
        exe = Path(tmp) / "AgenticMcp.Agent.ProbeService.exe"
        srv = serve(Path(tmp), port)
        try:
            ps(c, aid, f"""
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path C:\\yoloman-probe-svc | Out-Null
$wc = New-Object Net.WebClient; $wc.Proxy = $null
$wc.DownloadFile('http://{LAN_IP}:{port}/{exe.name}', 'C:\\yoloman-probe-svc\\ProbeService.exe')
'staged ' + (Get-Item C:\\yoloman-probe-svc\\ProbeService.exe).Length
""", timeout=600)
        finally:
            srv.shutdown()


def precedent_problem(case: str, name: str, doc: dict) -> str | None:
    """Every probe service was just created, so its leading finding must carry a precedent (B7); for
    precedent-change it must be the later change (7040 / the key write), not the creation."""
    if case in ("not-installed", "running") or not doc["findings"]:
        return None
    p = doc["findings"][0].get("precedent")
    if p is None:
        return "no precedent"
    if case == "precedent-change":
        created = [e["observed"] for e in doc["evidence"] if e["id"].startswith("evt:System:7045:")]
        if not (p["evidence_id"].startswith("evt:System:7040:") or p["evidence_id"] == f"reg:lastwrite:{name}"):
            return f"precedent {p['evidence_id']} is not the start-type change"
        if created and p["observed"] <= created[0]:
            return f"precedent at {p['observed']} is not after the creation at {created[0]}"
    return None


def leading(doc: dict) -> str:
    if doc["status"] == "running" and not doc["findings"]:
        return "running"
    f = doc["findings"][0] if doc["findings"] else {}
    return f"{f.get('rule_id')}/{f.get('certainty')}"


def diagnose_row(c, aid: str, name: str) -> dict | None:
    """Through Bossman's diagnosis endpoint (B8): asked, re-checked, stored — the row with the document."""
    r = c.post(f"/api/v1/agents/{aid}/diagnose", json={"name": name, "timeout_seconds": 120}, timeout=150)
    return r.json() if r.status_code == 200 else None


def diagnose(c, aid: str, name: str) -> dict | None:
    row = diagnose_row(c, aid, name)
    return row.get("diagnosis") if row else None


# --repair: the remedy as exported (B9, PowerShell form) is applied on the host, a new diagnosis must not report the
# rule any more (verify.rule_absent), and the rollback must bring it back. No new start in between: the rules must
# read the CURRENT state (LSA, ACL, configuration), not an event from before the repair.
REPAIRABLE = {"disabled", "logon-right", "logon-right-lsa", "access-denied"}


def repair_check(c, aid: str, name: str) -> dict:
    row = diagnose_row(c, aid, name)
    if not row:
        return {"ok": False, "why": "no diagnosis"}
    lead = (row["diagnosis"]["findings"] or [{}])[0]
    rem = lead.get("remedy")
    if not rem:
        return {"ok": False, "why": f"{lead.get('rule_id')} offers no remedy"}
    rule = rem["verify"]["rule_absent"]
    ex = c.get(f"/api/v1/diagnoses/{row['id']}/export/powershell").json()
    if not ex.get("apply"):
        return {"ok": False, "why": f"no PowerShell form: {ex.get('not_expressible')}"}
    out = {"rule": rule, "applied": ps(c, aid, ex["apply"] + "\n'applied'", timeout=120)["data"]["output"][-1].get("value")}
    after = diagnose(c, aid, name) or {}
    out["after"] = [f["rule_id"] for f in after.get("findings", [])]
    ps(c, aid, ex["rollback"] + "\n'rolled back'", timeout=120)
    back = diagnose(c, aid, name) or {}
    out["after_rollback"] = [f["rule_id"] for f in back.get("findings", [])]
    out["ok"] = rule not in out["after"] and rule in out["after_rollback"]
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="bossman-wintest")
    ap.add_argument("--only", default="")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--repair", action="store_true", help="also apply each exported remedy, verify, roll back")
    args = ap.parse_args()
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    c = bossman()
    aid = agent_id(c, args.host)
    ver = c.get(f"/api/v1/agents/{aid}").json().get("agent_version")
    results = json.loads(OUT.read_text()) if OUT.is_file() else {}
    failed = 0
    ps(c, aid, CLEANUP, timeout=120)
    if any(case in PROBE_SERVICE_CASES and (not only or case in only) for case, *_ in CASES):
        stage_probe_service(c, aid)
    try:
        for case, name, setup, want in CASES:
            if only and case not in only:
                continue
            if setup:
                ps(c, aid, setup + "; 'ok'", timeout=120)
            if case not in NO_START:
                # The start is EXPECTED to fail — that failure is what the SCM records and the probe diagnoses.
                ps(c, aid, f"sc.exe start {name} 2>&1 | Out-String", timeout=180)
                time.sleep(40 if case in ("timeout", "hang", "deadlock") else 10 if case == "crash" else 3)
            doc = diagnose(c, aid, name)
            if doc is None:
                row = {"case": case, "service": name, "want": want, "got": None, "ok": False}
            else:
                got, viol = leading(doc), C.violations(doc)
                prob = precedent_problem(case, name, doc)
                prec = (doc["findings"][0].get("precedent") or {}).get("evidence_id") if doc["findings"] else None
                row = {"case": case, "service": name, "want": want, "got": got,
                       "ok": got == want and not viol and prob is None, "precedent": prec, "precedent_problem": prob,
                       "contract_violations": viol, "summary": doc["summary"], "diagnosis": doc}
            if args.repair and case in REPAIRABLE and row["ok"]:
                row["repair"] = repair_check(c, aid, name)
                row["ok"] = row["repair"]["ok"]
                print(f"windows/{case}: repair {'ok' if row['ok'] else 'FAIL'} {row['repair']}", flush=True)
            row.update(agent=ver, at=time.strftime("%Y-%m-%dT%H:%M:%S"))
            results[f"windows|{case}"] = row
            failed += not row["ok"]
            print(f"windows/{case}: {'ok' if row['ok'] else 'FAIL'} want {want} got {row['got']} precedent {row.get('precedent')}"
                  + ("" if row["ok"] else f" — {row.get('precedent_problem') or row.get('summary', '')[:160]}"), flush=True)
    finally:
        if not args.keep:
            ps(c, aid, CLEANUP, timeout=120)
    OUT.write_text(json.dumps(dict(sorted(results.items())), indent=1, ensure_ascii=False) + "\n")
    print(f"{failed} case(s) failed (agent {ver})")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
