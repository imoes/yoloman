"""Break systemd units on purpose and check that `service_diagnose` names the cause — on a real systemd.

    .venv-host/bin/python -m bossman.tools.diagnosis_probe_linux [--family debian|redhat] [--only case,case] [--keep]

WHY. The rules (internal/diagnosis/systemd_rules.go) are tested on snapshots; a snapshot is my belief about what
systemd reports. This runs the agent's own module (`agentic-mcpd run-module service_diagnose`) in a fresh systemd
host pod of each family (the package-e2e `*-systemd` images, systemd as PID 1, privileged + tmpfs /run), against
units broken in one known way each, and compares the leading finding's rule and certainty with the expectation.
Every document is also checked against the contract (services/diagnosis_contract.py).

No Bossman involved: the pod does not enroll, the module is run through the agent's CLI. Results:
configs/diagnosis_probe_linux.json (one row per family × case, with the diagnosis).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path

from bossman.services import diagnosis_contract as C
from bossman.tools import qualify_packages as Q

CTX = "bossman-dev"
NS = "pkg-e2e"
OUT = Q._CONFIGS / "diagnosis_probe_linux.json"
ENV = {"NO_PROXY": "192.168.49.0/24,localhost,127.0.0.1", "no_proxy": "192.168.49.0/24,localhost,127.0.0.1"}

# (case, unit name, unit file text or None, extra setup shell, expected leading "rule/certainty")
CASES: list[tuple[str, str, str | None, str, str]] = [
    ("exec-missing", "probe-exec.service",
     "[Service]\nExecStart=/usr/local/bin/probe-missing\n", "", "svc.image_missing/Proven"),
    ("user-missing", "probe-user.service",
     "[Service]\nUser=nosuchuser\nExecStart=/bin/sleep 300\n", "", "svc.account_missing/Proven"),
    ("dependency", "probe-dep.service",
     "[Unit]\nRequires=probe-base.service\nAfter=probe-base.service\n[Service]\nExecStart=/bin/sleep 300\n",
     "printf '[Service]\\nType=oneshot\\nExecStart=/bin/false\\n' > /etc/systemd/system/probe-base.service",
     "svc.dependency_failed/Proven"),
    # masked: the unit must live in the vendor directory — `systemctl mask` cannot replace a unit file in
    # /etc/systemd/system (it would have to overwrite it), so a probe unit there stays unmasked.
    ("masked", "probe-masked.service", None,
     "printf '[Service]\\nExecStart=/bin/sleep 300\\n' > /usr/lib/systemd/system/probe-masked.service; "
     "systemctl daemon-reload; systemctl mask probe-masked.service",
     "svc.disabled/Proven"),
    ("exit-code", "probe-exit.service",
     "[Service]\nExecStart=/bin/sh -c 'echo \"probe: unknown directive lisen\" >&2; exit 3'\n", "",
     "svc.exits_immediately/Proven"),
    ("crash", "probe-crash.service",
     "[Service]\nExecStart=/bin/sh -c 'kill -SEGV $$$$'\n", "", "svc.crash/Proven"),
    ("timeout", "probe-timeout.service",
     "[Service]\nType=notify\nTimeoutStartSec=2\nExecStart=/bin/sleep 60\n", "", "svc.timeout/Proven"),
    ("start-limit", "probe-limit.service",
     "[Unit]\nStartLimitIntervalSec=60\nStartLimitBurst=2\n[Service]\nRestart=always\nRestartSec=0\n"
     "ExecStart=/bin/false\n", "", "svc.start_limit/Proven"),
    ("credentials", "probe-cred.service",
     "[Service]\nLoadCredential=secret:/nonexistent/probe-secret\nExecStart=/bin/sleep 300\n", "",
     "svc.access_denied/Proven"),
    ("condition", "probe-cond.service",
     "[Unit]\nConditionPathExists=/nonexistent/probe\n[Service]\nExecStart=/bin/sleep 300\n", "",
     "svc.condition_failed/Proven"),
    # precedent: the program is made non-executable AFTER the unit was written — the newer change must be the one
    # named, read from the inode change time on the real filesystem.
    ("precedent-chmod", "probe-prec.service",
     "[Service]\nExecStart=/usr/local/bin/probe-prog\n",
     "printf '#!/bin/sh\\nexit 0\\n' > /usr/local/bin/probe-prog; chmod +x /usr/local/bin/probe-prog; sleep 3; "
     "chmod -x /usr/local/bin/probe-prog",
     "svc.image_missing/Likely"),
    # B14: a start that never ends — Type=notify, the program never says ready, no start timeout: the threads' kernel
    # wait channels are the evidence (Likely: systemd itself has not given up)
    ("hang", "probe-hang.service",
     "[Service]\nType=notify\nTimeoutStartSec=infinity\nExecStart=/bin/sleep 600\n", "", "svc.timeout/Likely"),
    # B14: a real crash — a tiny static binary (built by the probe, copied in) dereferences a bad pointer in crashy();
    # the kernel logs the fault, the agent resolves the address to the function from the binary's own symbols
    ("linux-crash", "probe-nativecrash.service",
     "[Service]\nExecStart=/usr/local/bin/yoloman-crasher\n", "", "svc.crash/Proven"),
    ("not-installed", "probe-nosuch.service", None, "", "svc.not_installed/Proven"),
    ("stopped-cleanly", "probe-clean.service",
     "[Service]\nType=oneshot\nExecStart=/bin/true\n", "", "svc.stopped_cleanly/Proven"),
    ("running", "probe-run.service",
     "[Service]\nExecStart=/bin/sleep infinity\n", "", "running"),
]


def kubectl(*argv: str, stdin: str | None = None, timeout: int = 180) -> subprocess.CompletedProcess:
    return subprocess.run(["kubectl", "--context", CTX, "-n", NS, *argv], input=stdin, capture_output=True,
                          text=True, timeout=timeout, env={**os.environ, **ENV})


def sh(pod: str, script: str, timeout: int = 120) -> subprocess.CompletedProcess:
    return kubectl("exec", pod, "--", "sh", "-c", script, timeout=timeout)


# The precedent each case must carry on its leading finding. Default for a case that writes its unit: that unit file
# (it is the newest change of the target). None = no expectation (nothing written, or running).
PRECEDENT = {"precedent-chmod": "file:changed:/usr/local/bin/probe-prog"}
# Cases whose program belongs to a package: the package's last change must be read (dpkg.log / rpm).
OWNER_PKG = {"exit-code", "crash"}


def want_precedent(name: str, unit: str, text: str | None) -> str | None:
    if name in PRECEDENT:
        return PRECEDENT[name]
    return f"file:changed:/etc/systemd/system/{unit}" if text is not None and name != "running" else None


def host_image(family: str) -> str:
    state = json.loads((Path.home() / ".local/state/agentic-batches/pkg-e2e-images.json").read_text())
    return state[f"{family}_host"]


def host_up(name: str, family: str) -> None:
    pod = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": name, "labels": {"app": "diagnosis-probe"}},
           "spec": {"hostname": name, "restartPolicy": "Never", "containers": [{
               "name": "host", "image": host_image(family), "imagePullPolicy": "Never",
               "securityContext": {"privileged": True},
               "volumeMounts": [{"name": "run", "mountPath": "/run"}, {"name": "runlock", "mountPath": "/run/lock"},
                                {"name": "tmp", "mountPath": "/tmp"}]}],
               "volumes": [{"name": "run", "emptyDir": {"medium": "Memory"}},
                           {"name": "runlock", "emptyDir": {"medium": "Memory"}}, {"name": "tmp", "emptyDir": {}}]}}
    r = kubectl("apply", "-f", "-", stdin=json.dumps(pod))
    if r.returncode != 0:
        raise RuntimeError(r.stderr[-300:])
    kubectl("wait", "--for=condition=Ready", f"pod/{name}", "--timeout=180s", timeout=240)
    for _ in range(60):     # systemd up: is-system-running answers (running/degraded/starting)
        r = sh(name, "systemctl is-system-running 2>/dev/null; true")
        if r.stdout.strip() in ("running", "degraded"):
            return
        time.sleep(2)


def leading(doc: dict) -> str:
    if doc["status"] == "running" and not doc["findings"]:
        return "running"
    f = doc["findings"][0] if doc["findings"] else {}
    return f"{f.get('rule_id')}/{f.get('certainty')}"


def build_crasher() -> str:
    """A static, unstripped ELF that faults in crashy() — the input for the crash-location test. Built here (the pods
    have no compiler), copied into the pod; its own symbol table names the function, no debuginfod needed."""
    import subprocess as _sp, tempfile
    cc = shutil.which("cc") or shutil.which("gcc")
    if not cc:
        return ""
    out = Path(tempfile.gettempdir()) / "yoloman-crasher"
    src = out.with_suffix(".c")
    src.write_text("int crashy(int x){volatile int*p=(int*)16;return *p+x;} int main(){return crashy(1);}\n")
    r = _sp.run([cc, "-O0", "-no-pie", "-static", "-g", "-o", str(out), str(src)], capture_output=True, text=True)
    return str(out) if r.returncode == 0 else ""


def probe_case(pod: str, case: tuple, crasher: str = "") -> dict:
    name, unit, text, setup, want = case
    if name == "linux-crash":
        if not crasher:
            return {"case": name, "unit": unit, "want": want, "got": None, "ok": False, "error": "no C compiler to build the crasher"}
        kubectl("cp", crasher, f"{pod}:/usr/local/bin/yoloman-crasher")
        sh(pod, "chmod +x /usr/local/bin/yoloman-crasher")
    if text is not None:
        sh(pod, f"cat > /etc/systemd/system/{unit} <<'EOF'\n{text}EOF")
    if setup:
        sh(pod, setup)
    sh(pod, "systemctl daemon-reload")
    if name not in ("masked", "not-installed"):
        sh(pod, f"systemctl start {unit} --no-block; true")
        time.sleep(35 if name == "hang" else 6 if name in ("start-limit", "timeout", "linux-crash") else 3)
        if name == "start-limit":
            sh(pod, f"systemctl start {unit}; sleep 2; true")
    r = sh(pod, "agentic-mcpd run-module service_diagnose --json " + json.dumps(json.dumps({"name": unit})), 120)
    try:
        doc = json.loads(r.stdout)["data"]["diagnosis"]
    except (ValueError, KeyError, TypeError):
        return {"case": name, "unit": unit, "want": want, "got": None, "ok": False,
                "error": (r.stderr or r.stdout)[-400:]}
    got = leading(doc)
    viol = C.violations(doc)
    prec_want = want_precedent(name, unit, text)
    prec = ((doc["findings"][0].get("precedent") or {}) if doc["findings"] else {}).get("evidence_id")
    problems = []
    if prec_want is not None and prec != prec_want:
        problems.append(f"precedent {prec} (want {prec_want})")
    if name in OWNER_PKG and not any(e["id"].startswith("pkg:") and (e.get("raw") or {}).get("owner")
                                     for e in doc["evidence"]):
        problems.append("the program's package change was not read")
    return {"case": name, "unit": unit, "want": want, "got": got, "ok": got == want and not viol and not problems,
            "precedent": prec, "problems": problems,
            "contract_violations": viol, "summary": doc["summary"], "diagnosis": doc}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--family", choices=("debian", "redhat"), action="append")
    ap.add_argument("--only", default="")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    results = json.loads(OUT.read_text()) if OUT.is_file() else {}
    crasher = build_crasher()
    failed = 0
    for fam in args.family or ["debian", "redhat"]:
        pod = f"diag-{fam[:3]}-{uuid.uuid4().hex[:6]}"
        host_up(pod, fam)
        try:
            ver = sh(pod, "agentic-mcpd --version 2>&1 | head -1; true").stdout.strip()
            for case in CASES:
                if only and case[0] not in only:
                    continue
                r = probe_case(pod, case, crasher)
                r.update(family=fam, agent=ver, at=time.strftime("%Y-%m-%dT%H:%M:%S"))
                results[f"{fam}|{case[0]}"] = r
                failed += not r["ok"]
                print(f"{fam}/{case[0]}: {'ok' if r['ok'] else 'FAIL'} want {r['want']} got {r['got']}"
                      + f" precedent {r.get('precedent')}"
                      + (f" — {r.get('problems') or r.get('summary', r.get('error', ''))}"[:200] if not r["ok"] else ""), flush=True)
        finally:
            if not args.keep:
                kubectl("delete", "pod", pod, "--wait=false", "--grace-period=1", "--ignore-not-found")
    OUT.write_text(json.dumps(dict(sorted(results.items())), indent=1, ensure_ascii=False) + "\n")
    print(f"{failed} case(s) failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
