"""Run the diagnosis Ansible remedy export against a REAL Linux host and prove it does what it says (plan B9).

    .venv-host/bin/python -m bossman.tools.ansible_remedy_probe_linux [--family debian|redhat] [--keep]

WHY. `services/diagnosis_export.ansible()` turns a remedy into an apply playbook and a rollback playbook; the unit
tests only check the YAML and ansible-lint. This closes the loop on a real systemd: for two cases whose remedy uses a
different FQCN module it breaks a unit, diagnoses it with the agent's own module, exports the remedy, and runs BOTH
playbooks through the kubernetes.core.kubectl connection (no SSH — the modules run inside the pod), then checks the
OBSERVABLE host state flips and flips back:

  - user-missing -> ansible.builtin.user            account absent -> present -> absent (getent)
  - masked       -> ansible.builtin.systemd_service  is-enabled masked -> not-masked -> masked

A re-diagnosis is recorded too, with one caveat it makes explicit: creating the missing account does not by itself
clear `svc.account_missing`, because `systemctl show` still reports the unit's LAST (failed) invocation until the unit
is restarted — so the authoritative proof that the Ansible module changed the host is the observable (getent), not the
re-diagnosis. For `masked`, unmasking is enough for the state to flip, and the re-diagnosis flips with it.

No Bossman, no enrollment: the module is run through the agent's CLI, the playbooks through ansible-playbook on this
host. Results: configs/ansible_remedy_probe_linux.json.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from bossman.services import diagnosis_export as DX
from bossman.tools import diagnosis_probe_linux as P
from bossman.tools import qualify_packages as Q

OUT = Q._CONFIGS / "ansible_remedy_probe_linux.json"
CASES = ("user-missing", "masked")


def _diagnose(pod: str, unit: str) -> dict:
    r = P.sh(pod, "agentic-mcpd run-module service_diagnose --json " + json.dumps(json.dumps({"name": unit})), 120)
    return json.loads(r.stdout)["data"]["diagnosis"]


def _leading(doc: dict) -> str:
    if doc.get("findings"):
        f = doc["findings"][0]
        return f"{f.get('rule_id')}/{f.get('certainty')}"
    return doc.get("status", "?")


def _run_playbook(workdir: Path, name: str, text: str, inv: Path) -> subprocess.CompletedProcess:
    pb = workdir / name
    pb.write_text(text)
    env = {**os.environ, "ANSIBLE_NOCOLOR": "1", **P.ENV}
    return subprocess.run(["ansible-playbook", "-i", str(inv), str(pb)], capture_output=True, text=True,
                          env=env, timeout=300)


def _observe(pod: str, case: str, unit: str, acct: str) -> str:
    if case == "user-missing":
        return P.sh(pod, f"getent passwd {acct} >/dev/null && echo PRESENT || echo ABSENT").stdout.strip().splitlines()[-1]
    return P.sh(pod, f"systemctl is-enabled {unit} 2>&1; true").stdout.strip()


def probe_case(pod: str, case: str, workdir: Path) -> dict:
    _, unit, textu, setup, _want = next(c for c in P.CASES if c[0] == case)
    if textu is not None:
        P.sh(pod, f"cat > /etc/systemd/system/{unit} <<'EOF'\n{textu}EOF")
    if setup:
        P.sh(pod, setup)
    P.sh(pod, "systemctl daemon-reload")
    if case != "masked":
        P.sh(pod, f"systemctl start {unit} --no-block; true")
        time.sleep(3)

    doc = _diagnose(pod, unit)
    exp = DX.export(doc, "ansible", [])
    acct = doc["findings"][0]["remedy"]["target"]["id"] if doc.get("findings") else ""
    host = doc.get("host", pod)
    inv = workdir / f"{case}.ini"
    interp = P.sh(pod, "command -v python3 || echo /usr/bin/python3").stdout.strip().splitlines()[0]
    inv.write_text(f"{host} ansible_connection=kubernetes.core.kubectl ansible_kubectl_pod={pod} "
                   f"ansible_kubectl_namespace={P.NS} ansible_kubectl_context={P.CTX} "
                   f"ansible_python_interpreter={interp}\n")

    before = _observe(pod, case, unit, acct)
    ap = _run_playbook(workdir, f"{case}-apply.yml", exp["apply"], inv)
    after_apply = _observe(pod, case, unit, acct)
    re_apply = _leading(_diagnose(pod, unit))
    rb = _run_playbook(workdir, f"{case}-rollback.yml", exp["rollback"], inv)
    after_rb = _observe(pod, case, unit, acct)
    re_rb = _leading(_diagnose(pod, unit))

    changed = "changed=1" in ap.stdout
    if case == "user-missing":
        state_ok = before == "ABSENT" and after_apply == "PRESENT" and after_rb == "ABSENT"
    else:
        state_ok = before == "masked" and after_apply != "masked" and after_rb == "masked"
    ok = ap.returncode == 0 and rb.returncode == 0 and changed and state_ok and not exp["not_expressible"]
    return {"case": case, "unit": unit, "module": "ansible.builtin.user" if case == "user-missing"
            else "ansible.builtin.systemd_service", "diagnosis": _leading(doc), "ok": ok,
            "apply_rc": ap.returncode, "rollback_rc": rb.returncode, "changed": changed,
            "not_expressible": exp["not_expressible"],
            "observable": {"before": before, "after_apply": after_apply, "after_rollback": after_rb},
            "rediagnosis": {"after_apply": re_apply, "after_rollback": re_rb},
            "apply_tail": "" if ap.returncode == 0 else (ap.stdout + ap.stderr)[-600:]}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--family", choices=("debian", "redhat"), default="debian")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()
    workdir = Path(tempfile.mkdtemp(prefix="ansible-remedy-probe-"))
    results = json.loads(OUT.read_text()) if OUT.is_file() else {}
    pod = f"ansx-{args.family[:3]}-{uuid.uuid4().hex[:6]}"
    P.host_up(pod, args.family)
    failed = 0
    try:
        ver = P.sh(pod, "agentic-mcpd --version 2>&1 | head -1; true").stdout.strip()
        for case in CASES:
            r = probe_case(pod, case, workdir)
            r.update(family=args.family, agent=ver, at=time.strftime("%Y-%m-%dT%H:%M:%S"))
            results[f"{args.family}|{case}"] = r
            failed += not r["ok"]
            o = r["observable"]
            print(f"{args.family}/{case} ({r['module']}): {'ok' if r['ok'] else 'FAIL'} "
                  f"apply_rc={r['apply_rc']} rb_rc={r['rollback_rc']} changed={r['changed']} "
                  f"observable {o['before']} -> {o['after_apply']} -> {o['after_rollback']}"
                  + ("" if r["ok"] else f"  {r['apply_tail'][-200:]}"), flush=True)
    finally:
        if not args.keep:
            P.kubectl("delete", "pod", pod, "--wait=false", "--grace-period=1", "--ignore-not-found")
    OUT.write_text(json.dumps(dict(sorted(results.items())), indent=1, ensure_ascii=False) + "\n")
    print(f"{failed} case(s) failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
