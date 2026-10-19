"""The Bossman path of the package e2e: every catalog role through the REAL role-deployment API, on a fresh host.

    .venv-host/bin/python -m bossman.tools.package_e2e_bossman [--family debian|redhat] [--only nginx,chrony]
                                                               [--limit N] [--parallel 3] [--check-only]

package_e2e.py proves the agent's modules configure a package. This proves the PRODUCT does: the wizard's install
path — preview → create → reconcile, the same calls the Roles & Features page makes — against a host Bossman manages.

ONE FRESH HOST PER ROLE. A role deployment installs a package; on a shared host five hundred roles would collide
(postfix and exim are alternatives). So each role gets its own agent pod in minikube: it enrolls with Bossman
(`agentic-mcpd register`), is reachable through a NodePort, receives the deployment, is read back, and is removed —
pod, service, deployment and agent record. Reachability is the same as deploy/test-images/agent-hosts.sh.

WHAT IS RECORDED, per (family, role), in configs/package_e2e_bossman_results.jsonl:
  state        the deployment target's final state (compliant | noncompliant | error | blocked | not_applicable)
               plus Bossman's own last_error — the reason the product shows the operator
  file         the configured file read back from the host (`slurp`), so "compliant" is checked, not believed
  unstable     compliant at verification, but the unit is down 10 s later (a daemon that dies after starting)
  family_template  whether the file is the family's own template (the wizard used to render Debian's everywhere)
  check        the package's checker run on the host via the `command` tool, when one is known
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import os
import queue
import subprocess
import threading
import time
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

import httpx

from bossman.tools._paths import configs_dir

CONFIGS = configs_dir(__file__)
RESULTS = CONFIGS / "package_e2e_bossman_results.jsonl"
#: Values only a site has (a tunnel address, a domain, a passphrase), for roles whose wizard REQUIRES them. Test
#: inputs, from documentation ranges (192.0.2.0/24, 10.53.0.0/16, *.example.test) — never a real site's values. Without
#: them such a role ends `preview-refused` naming the missing fields, which is the product working; with them the
#: run shows the role configures a daemon that runs. {family: {role: {parameter: value}}}.
SITE_VALUES = CONFIGS / "package_e2e_site_values.json"
CATALOG = CONFIGS / "package_catalog.json"
VALIDATORS = CONFIGS / "package_validators.json"
IMAGES = os.path.expanduser("~/.local/state/agentic-batches/pkg-e2e-images.json")
API = os.environ.get("BOSSMAN_URL", "http://localhost:8123")
USER, PASSWORD = os.environ.get("BOSSMAN_USER", "admin"), os.environ.get("BOSSMAN_PASSWORD", "admin123")
CTX, NS = "bossman-dev", "pkg-e2e-hosts"
NODE_IP = os.environ.get("PKG_E2E_NODE_IP", "192.168.49.2")
ENROLL = os.environ.get("BOSSMAN_ENROLL_URL", "http://192.168.49.1:8123")
PROXY = os.environ.get("YOLOMAN_HTTP_PROXY", "http://proxy.example.internal:80")
TERMINAL = {"compliant", "noncompliant", "error", "blocked", "not_applicable", "unmanaged"}
_lock = threading.Lock()
#: NodePorts are a pool, returned when a host is torn down: a plain counter ran out after 100 roles of 296.
_ports: "queue.Queue[int]" = queue.Queue()
for _p in range(30900, 31000):
    _ports.put(_p)


def _env():
    return {**os.environ, "NO_PROXY": "192.168.49.0/24,localhost,127.0.0.1", "no_proxy": "192.168.49.0/24,localhost,127.0.0.1"}


def _ports_in_use() -> set[int]:
    """NodePorts the cluster has already allocated — a host kept by an earlier run (`--keep`) still holds its port,
    and this process's pool starts from 30900 again: the next run's pod create then failed with "provided port is
    already allocated" (measured: a kept Debian host on 30900, the RedHat run right after it)."""
    r = subprocess.run(["kubectl", "--context", CTX, "get", "svc", "-A", "-o",
                        "jsonpath={range .items[*]}{range .spec.ports[*]}{.nodePort} {end}{end}"],
                       capture_output=True, text=True, timeout=60, env=_env())
    return {int(x) for x in r.stdout.split() if x.isdigit()}


def _free_port() -> int:
    """The next pool port no Service in the cluster holds; a held one goes back to the END of the pool."""
    for _ in range(_ports.qsize() + 1):
        port = _ports.get()
        if port not in _ports_in_use():
            return port
        _ports.put(port)
    raise RuntimeError("no free NodePort in 30900-30999: every one is held by a Service in the cluster")


def kubectl(*argv: str, stdin: str | None = None, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(["kubectl", "--context", CTX, "-n", NS, *argv], input=stdin, capture_output=True,
                          text=True, timeout=timeout, env=_env())


class Bossman:
    def __init__(self) -> None:
        # 900 s like Bossman's own long-tool timeout (agent_client._LONG_TOOLS): installing pacemaker + corosync + pcs
        # outlasted 120 s and the row read "infra-error: ReadTimeout" while the install was still running.
        self.http = httpx.Client(base_url=API, timeout=900, trust_env=False)
        tok = self.http.post("/api/v1/auth/login", json={"username": USER, "password": PASSWORD}).json()["access_token"]
        self.http.headers["Authorization"] = f"Bearer {tok}"

    def get(self, path: str, **kw):
        r = self.http.get(path, **kw)
        r.raise_for_status()
        return r.json()

    def post(self, path: str, body: dict | None = None):
        return self.http.post(path, json=body or {})


def host_up(name: str, family: str, port: int, image: str) -> None:
    manifest = {
        "apiVersion": "v1", "kind": "List", "items": [
            {"apiVersion": "v1", "kind": "Service", "metadata": {"name": name, "labels": {"app": "e2e-role-host"}},
             "spec": {"type": "NodePort", "selector": {"host": name},
                      "ports": [{"name": "agent", "port": port, "targetPort": port, "nodePort": port}]}},
            {"apiVersion": "v1", "kind": "Pod",
             "metadata": {"name": name, "labels": {"app": "e2e-role-host", "host": name, "family": family}},
             "spec": {"hostname": name, "restartPolicy": "Never", "containers": [{
                 # systemd as PID 1 (the *-systemd host image): the agent runs as the packaged service and the
                 # wizard's service step meets a real init. systemd in a container needs privileges and a tmpfs /run.
                 "name": "host", "image": image, "imagePullPolicy": "Never",
                 "securityContext": {"privileged": True},
                 "env": [{"name": "E2E_ENROLL_URL", "value": ENROLL}, {"name": "E2E_NAME", "value": name},
                         {"name": "E2E_ADDRESS", "value": f"{NODE_IP}:{port}"}, {"name": "E2E_WRITE", "value": "true"},
                         {"name": "http_proxy", "value": PROXY}, {"name": "https_proxy", "value": PROXY},
                         {"name": "no_proxy", "value": "192.168.49.0/24,.example.internal,localhost"}],
                 "volumeMounts": [{"name": "run", "mountPath": "/run"}, {"name": "runlock", "mountPath": "/run/lock"},
                                  {"name": "tmp", "mountPath": "/tmp"}],
                 "resources": {"requests": {"cpu": "100m", "memory": "192Mi"}, "limits": {"memory": "3Gi"}}}],
                 "volumes": [{"name": "run", "emptyDir": {"medium": "Memory"}},
                             {"name": "runlock", "emptyDir": {"medium": "Memory"}},
                             {"name": "tmp", "emptyDir": {}}]}},
        ]}
    r = kubectl("apply", "-f", "-", stdin=json.dumps(manifest))
    if r.returncode != 0:
        raise RuntimeError(f"pod create: {r.stderr.strip()[:300]}")


def _load_json(path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}



def _forget_agent(bm, agent: dict, out: dict) -> None:
    """Delete the throwaway host's agent record, and SAY so when that fails. The status used to go unread, and 36
    agents of deleted pods piled up in Bossman unnoticed (the delete raced the poller — fixed in the endpoint)."""
    r = bm.http.delete(f"/api/v1/agents/{agent['id']}")
    if r.status_code not in (204, 404):
        out["cleanup_failed"] = f"DELETE agent {agent.get('name') or agent['id']}: HTTP {r.status_code} {r.text[:200]}"

def host_down(name: str) -> None:
    kubectl("delete", "pod", name, "--wait=false", "--grace-period=1", "--ignore-not-found")
    # The Service is waited for: its NodePort goes back to the pool and the next host may claim it at once.
    kubectl("delete", "svc", name, "--ignore-not-found", timeout=120)


def _pod_ended(name: str) -> str | None:
    """Why the host pod is no longer running, or None while it runs. A systemd PID 1 that exits 255 within a second,
    printing nothing, is what an exhausted fs.inotify.max_user_instances looks like (shared per uid by every root
    process of the host kernel — measured 2026-10-10: ten hosts in a row, the previous image too, all fine again after
    leftover systemd pods were deleted)."""
    r = kubectl("get", "pod", name, "-o", "jsonpath={.status.containerStatuses[0].state.terminated}")
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        term = json.loads(r.stdout)
    except ValueError:
        return f"pod terminated: {r.stdout.strip()[:200]}"
    why = f"host pod exited {term.get('exitCode')} ({term.get('reason')})"
    if term.get("exitCode") == 255:
        why += " — systemd as PID 1 gave up at start; check the node's inotify instances (fs.inotify.max_user_instances)"
    return why


def wait_enrolled(bm: Bossman, name: str, timeout: int = 300) -> dict:
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for a in bm.get("/api/v1/agents"):
            if a["name"] == name and a.get("enrollment_state") == "enrolled":
                bm.post(f"/api/v1/agents/{a['id']}/poll-now")
                return a
        ended = _pod_ended(name)
        if ended:
            raise RuntimeError(f"{name}: {ended}")
        time.sleep(3)
    raise TimeoutError(f"{name} did not enroll within {timeout}s")


def tool(bm: Bossman, agent_id: str, name: str, params: dict) -> dict:
    r = bm.post(f"/api/v1/agents/{agent_id}/tools/{name}", {"params": params})
    try:
        return r.json()
    except ValueError:
        return {"status": r.status_code, "text": r.text[:300]}


def run_role(bm: Bossman, family: str, role: str, entry: dict, image: str, validators: dict,
             keep: bool = False) -> dict:
    port = _free_port()
    name = f"e2e-w-{family[:3]}-{uuid.uuid4().hex[:6]}"
    out: dict = {"family": family, "role": role, "host": name, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    t0 = time.monotonic()
    agent = None
    dep_id = None
    try:
        host_up(name, family, port, image)
        agent = wait_enrolled(bm, name)
        target = {"type": "host", "id": agent["id"]}
        site = ((_load_json(SITE_VALUES).get(family) or {}).get(role)) or {}
        items = [{"catalog_name": role, "parameters": dict(site)}]
        if site:
            out["site_values"] = sorted(site)
        pv = bm.post("/api/v1/role-deployments/preview", {"target": target, "items": items})
        if pv.status_code != 200:
            out.update(state="preview-refused", reason=pv.text[:400])
            return out
        preview = pv.json()
        if preview.get("artifacts") and any(a.get("not_applicable") for a in preview["artifacts"]):
            out["not_applicable"] = [x for a in preview["artifacts"] for x in a.get("not_applicable") or []]
        cr = bm.post("/api/v1/role-deployments", {"target": target, "items": items, "name": f"e2e {role} {family}",
                                                  "preview_hash": preview["preview_hash"]})
        if cr.status_code not in (200, 201):
            out.update(state="create-refused", reason=cr.text[:400])
            return out
        dep = cr.json()
        dep_id = dep["id"]
        if dep.get("status") == "pending_approval":
            out.update(state="pending_approval", reason="a single-host deployment by an admin should not need approval")
            return out
        bm.post(f"/api/v1/role-deployments/{dep_id}/reconcile")
        state, last_error = "pending", None
        while time.monotonic() - t0 < 1200:
            detail = bm.get(f"/api/v1/role-deployments/{dep_id}")
            tg = (detail.get("targets") or [{}])[0]
            state, last_error = tg.get("state"), tg.get("last_error")
            # "not reported its OS family yet" is transient: the worker retries once the host's facts arrive.
            if state == "not_applicable" and "not reported its OS family" in str(last_error or ""):
                time.sleep(5)
                continue
            if state in TERMINAL:
                break
            time.sleep(5)
        out.update(state=state, last_error=last_error)
        branch = (entry.get("families") or {}).get(family) or {}
        unit = branch.get("service") or ""
        if state == "compliant" and unit:
            # Compliant is decided right after the apply; a daemon that dies seconds later (radicale did) would be
            # counted as working. Ask the host again, independently, 10 s on.
            later = tool(bm, agent["id"], "shell", {"cmd": f"sleep 10; systemctl is-active {unit} || true"})
            now = str(((later.get("result") or later).get("data") or {}).get("stdout", "")).strip()
            if now not in ("active", "activating", "reloading", "inactive"):   # inactive: a finished oneshot/timer
                jr = tool(bm, agent["id"], "command", {"cmd": f"journalctl -u {unit} -n 5 -o cat --no-pager"})
                tail = str(((jr.get("result") or jr).get("data") or {}).get("stdout", "")).strip()[-300:]
                out.update(state="unstable", last_error=f"compliant at verification, {unit} is {now!r} 10 s later — {tail}")
        path = branch.get("config_path")
        if path and entry.get("template"):
            got = tool(bm, agent["id"], "slurp", {"path": path})
            data = (got.get("result") or got).get("data") if isinstance(got, dict) else None
            content = None
            if isinstance(data, dict) and data.get("content"):
                content = base64.b64decode(data["content"]).decode(errors="replace") if data.get("encoding") == "base64" \
                    else data["content"]
            out["file"] = {"path": path, "bytes": len(content) if content else None,
                           "head": (content or "")[:160]}
        # The checker may live in ANY of the role's packages (cupsd is in cups-daemon, not cups), so the first one
        # that has a verified checker counts — the first package alone missed those.
        fam_validators = validators.get(family) or {}
        from bossman.tools.package_e2e import verified   # one rule: only checkers that accepted the shipped file
        check = next((fam_validators[p]["check_cmd"] for p in (branch.get("packages") or [role])
                      if (fam_validators.get(p) or {}).get("check_cmd") and verified(fam_validators[p])),
                     None) or entry.get("validate_cmd")
        if check and state == "compliant":
            cmd = check.replace("{path}", path or "")
            # Through `shell`, not `command`: a checker is a shell line (`postfix -c "$(dirname …)" check`, a
            # throwaway host key for sshd on EL) and `command` runs argv without a shell — measured: postfix got
            # the literal `$(dirname` and said "-c requires absolute pathname".
            res = tool(bm, agent["id"], "shell", {"cmd": cmd})
            r = res.get("result") or res
            out["check"] = {"cmd": cmd, "rc": (r.get("data") or {}).get("rc") if isinstance(r, dict) else None,
                            "output": str((r.get("data") or {}).get("stderr") or (r.get("data") or {}).get("stdout")
                                          or r.get("msg") or "")[-400:] if isinstance(r, dict) else str(r)[-400:]}
            # A role Bossman calls compliant whose file the package's own checker rejects is NOT a pass: the row
            # said "compliant" next to rc=1. The role's state is kept beside it.
            if out["check"]["rc"] != 0:
                out["role_state"] = state
                out["state"] = "validate-failed" if out["check"]["rc"] is not None else "validate-unknown"
    except Exception as exc:  # noqa: BLE001 — one role's infrastructure failure must not stop the run
        out.update(state="infra-error", reason=f"{type(exc).__name__}: {str(exc)[:300]}")
    finally:
        if keep:
            out["kept"] = {"pod": name, "agent_id": (agent or {}).get("id"), "deployment_id": dep_id}
        else:
            if dep_id:
                bm.post(f"/api/v1/role-deployments/{dep_id}/retire", {"behavior": "unmanage"})
            host_down(name)
            if agent:
                _forget_agent(bm, agent, out)
            _ports.put(port)
        out["seconds"] = round(time.monotonic() - t0, 1)
    return out


# The daemon's own log file, when its unit passes one (`--logfile=`/`--log-file=`, possibly as ${VAR} from the unit's
# EnvironmentFile): its last lines. Empty when the unit names none.
LOGFILE_TAIL = (
    "f=$(systemctl cat {unit} 2>/dev/null | grep -oE -- '--log-?file[= ][^ ]+' | head -1 | sed -E 's/--log-?file[= ]//');"
    " case \"$f\" in *'$'*) for e in $(systemctl show -p EnvironmentFiles --value {unit} | awk '{{print $1}}');"
    " do set -a; . \"${{e#-}}\" 2>/dev/null; set +a; done; f=$(eval echo \"$f\");; esac;"
    " [ -n \"$f\" ] && [ -f \"$f\" ] && tail -n 12 \"$f\" || true")


# Why a unit does not run with the configuration its package SHIPS — read from its journal, first match wins.
# The causes are not all "the container": a daemon that needs site values (a realm, a subnet, a ring file, a server
# type) fails on every fresh host, and THAT is what the role is for — so when the role fails too, its wizard lacks a
# required value. Order matters: a container condition is checked before the generic "file missing".
SHIPPED_CAUSES: list[tuple[str, str, str]] = [
    ("dependency", r"Dependency failed", "a unit it requires failed first"),
    ("masked", r"^UNIT-STATE: masked", "the package installs the unit MASKED (Debian's hostapd) — a restart is "
     "refused until something unmasks it"),
    ("container", r"ConditionVirtualization=!container|Cannot daemonize|audit.*netlink|executable 'modprobe'|"
     r"ip6?tables(-legacy)?-restore|Operation not permitted|swapon failed|sys-kernel-config\.mount is masked",
     "the unit refuses to run in a container, or needs a kernel facility the container does not grant"),
    ("hardware", r"coretemp|hdaps|NetworkManager|[Mm]odem|/dev/tty|No such device|DEVICEOPENERROR|wlan|wifi"
                 r"|audio device|Cannot get card index",
     "the daemon drives hardware the test host does not have"),
    ("service-user-missing", r"217/USER", "the unit's User= does not exist — the package does not create it"),
    ("crash", r"status=(11/SEGV|6/ABRT|7/BUS)", "the daemon crashed with the shipped file"),
    ("missing-binary", r"203/EXEC|failed to spawn", "the unit starts a program that is not installed"),
    ("state-dir-permissions", r"Permission denied: '/var/(lib|cache|log)/",
     "the unit's user may not write the package's own state directory (it is root-owned) — a packaging defect"),
    ("shipped-config-invalid", r"compiled without|error parsing .* at \d+|unknown (directive|option)",
     "the package's own binary rejects the configuration the package ships — a packaging defect"),
    ("needs-init", r"--initdb|initialize the database", "the package needs a one-time initialisation before its "
     "first start — the role's runbook must run it"),
    ("needs-internet", r"Name or service not known|Temporary failure in name resolution",
     "the shipped file names an internet host (miredo's Teredo server) the isolated test host cannot resolve — a "
     "limit of the test, not of the role"),
    ("needs-peer", r"Connection refused|cmap key|/var/log/mail\.log|zmpkg\.pl|Can't connect to (local )?MySQL",
     "the daemon talks to another service (a backend, a cluster, a monitored daemon) that is not on the host"),
    ("needs-site-config", r"unmet condition check Condition(Path|File)|Assertion failed|not specified|"
     r"[Ff]atal configuration error|[Pp]lease (define|provide)|default realm|no configuration found|No such file or directory|"
     r"[Nn]ot configured|[Nn]o subnet|[Mm]issing .*(option|setting)|Error opening configuration file|No rules directory|"
     r"No entries found|needs to be enabled|no boot files|EXCEPTION",
     "the shipped file lacks values every site must supply — the role must ask for them"),
]


#: The rules of the agent's diagnosis (configs/diagnosis_rules.json) each journal cause corresponds to — the
#: cross-check of service_diagnose against this classifier. A cause may have more than one: needs-site-config is a
#: value missing (config_incomplete) OR a Condition*/Assert* on the missing config file (condition_failed) — the
#: classifier cannot tell them apart, the agent can (the swift units: "Assertion failed", the agent reads the
#: unit's own condition).
CAUSE_TO_RULE: dict[str, set[str]] = {
    "dependency": {"svc.dependency_failed"}, "masked": {"svc.disabled"}, "container": {"svc.container_limit"},
    "hardware": {"svc.device_missing"}, "service-user-missing": {"svc.account_missing"}, "crash": {"svc.crash"},
    "missing-binary": {"svc.image_missing"}, "state-dir-permissions": {"svc.access_denied"},
    "shipped-config-invalid": {"svc.config_invalid"}, "needs-init": {"svc.not_initialized"},
    "needs-internet": {"svc.network_unavailable"}, "needs-peer": {"svc.peer_unreachable"},
    "needs-site-config": {"svc.config_incomplete", "svc.condition_failed"}, "oneshot-finished": {"svc.stopped_cleanly"},
    "no-journal": {"svc.unexplained"}, "unclassified": {"svc.unexplained"},
}


def compare_diagnosis(cause: str, rules: list[str]) -> str:
    """agrees | agent-more-specific (the classifier found nothing, the agent names a cause) | disagrees."""
    if CAUSE_TO_RULE.get(cause, set()) & set(rules):
        return "agrees"
    if cause in ("no-journal", "unclassified") and any(r != "svc.unexplained" for r in rules):
        return "agent-more-specific"
    return "disagrees"


def shipped_cause(journal: str) -> tuple[str, str]:
    """`journal` may start with "UNIT-STATE: <is-enabled>" and "UNIT-TYPE: <Type>" lines (recorded by run_baseline)."""
    for cause, pattern, reason in SHIPPED_CAUSES:
        if re.search(pattern, journal or "", re.M):
            return cause, reason
    body = "\n".join(ln for ln in (journal or "").splitlines() if not ln.startswith("UNIT-"))
    if not body.strip():
        return "no-journal", "the unit wrote nothing to the journal"
    if re.search(r"^UNIT-TYPE: oneshot", journal or "", re.M) or re.search(r"Deactivated successfully|^Finished ", body, re.M):
        return "oneshot-finished", ("the unit is a oneshot that ran and finished — not running afterwards is its "
                                    "success, so `state: started` can never be compliant for it")
    return "unclassified", "no known cause matches the journal — read it"


def run_baseline(bm: Bossman, family: str, role: str, entry: dict, image: str) -> dict:
    """Is the role's daemon able to run in this container AT ALL? Install the package with the configuration it
    ships, start the unit, read its state and journal — no role, no template.

    Separates the two causes behind "service not running after the apply": the shipped config also fails
    (`shipped-fails`, with a named `cause`: container, hardware, needs-site-config, …) from the shipped config running
    fine (`template` — the role's configuration is what breaks it)."""
    port = _free_port()
    name = f"e2e-b-{family[:3]}-{uuid.uuid4().hex[:6]}"
    branch = (entry.get("families") or {}).get(family) or {}
    unit = branch.get("service") or ""
    out: dict = {"family": family, "role": role, "host": name, "baseline": True, "unit": unit,
                 "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    agent = None
    try:
        host_up(name, family, port, image)
        agent = wait_enrolled(bm, name)
        pkgs = branch.get("packages") or []
        tool(bm, agent["id"], "package", {"name": pkgs, "state": "present"})
        if not unit:
            out.update(verdict="no-unit", reason="the role names no service for this family")
            return out
        tool(bm, agent["id"], "service", {"name": unit, "state": "restarted"})
        # Read the state after the unit had time to fail: right after a restart a crashing Type=simple daemon is
        # "activating"/"active" for a second or two — radicale read "active" here and "failed" 7 s later.
        active = tool(bm, agent["id"], "shell", {"cmd": f"sleep 8; systemctl is-active {unit} || true"})
        state = str(((active.get("result") or active).get("data") or {}).get("stdout", "")).strip()
        journal = tool(bm, agent["id"], "command", {"cmd": f"journalctl -u {unit} --no-pager -n 15 -o cat"})
        # `shell`, not `command`: the agent's command module runs argv without a shell, so `;` and `||` were
        # passed to systemctl as arguments and the answers came back empty.
        props = tool(bm, agent["id"], "shell", {"cmd": f"systemctl show -p Type --value {unit}; "
                                                       f"systemctl is-enabled {unit} || true"})
        # Line by line, NOT strip()ped first: a masked unit prints an EMPTY Type line, and stripping shifted
        # "masked" into the type.
        lines = str(((props.get("result") or props).get("data") or {}).get("stdout", "")).split("\n") + ["", ""]
        unit_type, enabled = lines[0], lines[1]
        out["unit_type"], out["unit_enabled"] = unit_type.strip(), enabled.strip()
        out["journal"] = (f"UNIT-TYPE: {out['unit_type']}\nUNIT-STATE: {out['unit_enabled']}\n"
                          + str(((journal.get("result") or journal).get("data") or {}).get("stdout", ""))[-1500:])
        if state != "active":
            # Some daemons write their reason to their OWN log file, not the journal (svxlink: `--logfile=${LOGFILE}`
            # from /etc/default/svxlink; the journal only said "status=1/FAILURE"). The unit names that file.
            log = tool(bm, agent["id"], "shell", {"cmd": LOGFILE_TAIL.format(unit=unit)})
            tail = str(((log.get("result") or log).get("data") or {}).get("stdout", "")).strip()
            if tail:
                out["journal"] += "\nDAEMON-LOG:\n" + tail[-1200:]
        out["shipped_state"] = state
        out["verdict"] = "template" if state == "active" else "shipped-fails"
        if state != "active":
            out["cause"], out["cause_reason"] = shipped_cause(out["journal"])
            # The agent's own diagnosis of the same unit on the same host (service_diagnose, docs/diagnosis.md):
            # `cause` above is the regex classifier over the journal text and stays as the cross-check —
            # CAUSE_TO_RULE says which rule each cause should come out as; disagreements are reviewed, not hidden.
            diag = tool(bm, agent["id"], "service_diagnose", {"name": unit})
            doc = (((diag.get("result") or diag).get("data") or {}).get("diagnosis")) or {}
            if doc.get("findings"):
                lead = doc["findings"][0]
                out["diagnosis"] = {"rule_id": lead["rule_id"], "certainty": lead["certainty"],
                                    "claim": lead["claim"], "rules": [f["rule_id"] for f in doc["findings"]]}
                out["diagnosis_compared"] = compare_diagnosis(out["cause"], out["diagnosis"]["rules"])
                out["diagnosis_agrees"] = out["diagnosis_compared"] != "disagrees"
            else:
                out["diagnosis"] = {"error": str(diag)[:300]}
    except Exception as exc:  # noqa: BLE001
        out.update(verdict="infra-error", reason=f"{type(exc).__name__}: {str(exc)[:200]}")
    finally:
        host_down(name)
        if agent:
            _forget_agent(bm, agent, out)
        _ports.put(port)
    return out


BASELINE = CONFIGS / "package_e2e_bossman_baseline.jsonl"


def record_unavailable(catalog: dict, done: dict) -> int:
    """Rows for roles the catalog no longer installs on a family, so the result set stays current.

    The runner skips a branch marked `unavailable` (adminer, traefik … on AlmaLinux) or gone — and their last row,
    an install that failed before the catalog knew better, stood forever as "error". Each gets one row with the
    named state `unavailable` (the catalog's reason) or `not-in-family`, written once."""
    added = 0
    for (fam, role), prev in list(done.items()):
        entry = catalog.get(role) or {}
        branch = (entry.get("families") or {}).get(fam)
        if isinstance(branch, dict) and branch.get("unavailable"):
            state, reason = "unavailable", branch["unavailable"]
        elif not isinstance(branch, dict):
            state, reason = "not-in-family", f"the catalog offers {role!r} on no {fam} branch any more"
        else:
            continue
        if prev.get("state") == state:
            continue
        row = {"family": fam, "role": role, "state": state, "last_error": reason,
               "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
        with _lock, open(RESULTS, "a") as fh:
            fh.write(json.dumps(row) + "\n")
        done[(fam, role)] = row
        added += 1
    return added


def latest() -> dict:
    done = {}
    if RESULTS.is_file():
        for line in RESULTS.read_text().splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            done[(r["family"], r["role"])] = r
    return done


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--family", choices=("debian", "redhat"), action="append")
    ap.add_argument("--only", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--parallel", type=int, default=3)
    ap.add_argument("--check-only", action="store_true")
    ap.add_argument("--baseline", action="store_true",
                    help="for every role whose latest result says its service did not run, start the unit with the "
                         "SHIPPED config on a fresh host: verdict shipped-fails (with a cause) or template (runs)")
    ap.add_argument("--classify", action="store_true",
                    help="re-derive verdict/cause of every recorded baseline row from its journal (no pods)")
    ap.add_argument("--keep", action="store_true", help="leave host pod, agent and deployment in place (debugging)")
    ap.add_argument("--redo", default="infra-error,preview-refused,create-refused")
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    validators = json.loads(VALIDATORS.read_text()) if VALIDATORS.is_file() else {}
    images = json.loads(open(IMAGES).read())
    done = latest()
    marked = record_unavailable(catalog, done)
    if marked:
        print(f"{marked} role(s) now recorded as unavailable / not-in-family (the catalog's reason)", flush=True)
    if args.check_only:
        c = Counter((f, r.get("state")) for (f, _), r in done.items())
        for k, v in sorted(c.items(), key=lambda x: (x[0][0], str(x[0][1]))):
            print(f"{k[0]:8s} {str(k[1]):18s} {v}")
        return 0
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    redo = {s.strip() for s in args.redo.split(",") if s.strip()}
    todo = []
    for fam in args.family or ["debian", "redhat"]:
        for role, entry in sorted(catalog.items()):
            branch = (entry.get("families") or {}).get(fam)
            if not isinstance(branch, dict) or branch.get("unavailable") or entry.get("kind") not in ("role", "feature"):
                continue
            if only and role not in only:
                continue
            prev = done.get((fam, role))
            if prev and prev.get("state") not in redo and not only:
                continue
            todo.append((fam, role, entry))
    if args.limit:
        todo = todo[: args.limit]
    if args.classify:
        rows = [json.loads(line) for line in BASELINE.read_text().splitlines() if line.strip()]
        for row in rows:
            if row.get("verdict") in ("environment", "shipped-fails"):
                row["verdict"] = "shipped-fails"
                row["cause"], row["cause_reason"] = shipped_cause(row.get("journal") or "")
        BASELINE.write_text("".join(json.dumps(r) + "\n" for r in rows))
        last = {(r["family"], r["role"]): r for r in rows}
        print(Counter((r.get("verdict"), r.get("cause", "")) for r in last.values()))
        return 0
    bm = Bossman()
    if args.baseline:
        service_fail = [(f, r) for (f, r), row in done.items()
                        if "service" in str(row.get("last_error") or "") and row.get("state") in ("error", "noncompliant")
                        and (not only or r in only)]
        print(f"baseline: {len(service_fail)} role(s) whose service did not run", flush=True)
        with ThreadPoolExecutor(max_workers=max(1, args.parallel)) as pool:
            futs = [pool.submit(run_baseline, bm, f, r, catalog[r], images[f"{f}_host"]) for f, r in service_fail]
            for i, fut in enumerate(as_completed(futs), 1):
                row = fut.result()
                with _lock, open(BASELINE, "a") as fh:
                    fh.write(json.dumps(row) + "\n")
                print(f"[{i}/{len(service_fail)}] {row['family']}/{row['role']}: {row.get('verdict')} "
                      f"({row.get('shipped_state', '')})", flush=True)
        return 0
    print(f"package_e2e_bossman: {len(todo)} role(s), {args.parallel} at a time", flush=True)
    counts: Counter = Counter()
    with ThreadPoolExecutor(max_workers=max(1, args.parallel)) as pool:
        futs = [pool.submit(run_role, bm, fam, role, entry, images[f"{fam}_host"], validators, args.keep)
                for fam, role, entry in todo]
        for i, fut in enumerate(as_completed(futs), 1):
            r = fut.result()
            with _lock, open(RESULTS, "a") as fh:
                fh.write(json.dumps(r) + "\n")
            counts[r.get("state")] += 1
            extra = f" — {str(r.get('last_error') or r.get('reason') or '')[:120]}" if r.get("state") != "compliant" else ""
            print(f"[{i}/{len(todo)}] {r['family']}/{r['role']}: {r.get('state')}{extra} ({r.get('seconds')}s)",
                  flush=True)
    print("states:", dict(counts), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
