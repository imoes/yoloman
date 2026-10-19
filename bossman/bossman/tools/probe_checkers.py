"""Verify a package's own configuration checker on a real test host before the e2e suite trusts it.

    .venv-host/bin/python -m bossman.tools.probe_checkers [--only pkg,…] [--family debian|redhat] [--write]

WHY. Stage 3 of the template verification asks the package itself whether a written file is valid (`nginx -t`,
`named-checkconf`, …). A checker that is wrong — the wrong flag, a binary in another package, a command that also
needs a running daemon — would fail every template of that package and be read as "the templates are broken". So a
checker earns its place in configs/package_validators.json only after it ACCEPTED THE FILE THE PACKAGE SHIPS on a
fresh host of that family: same image as the pod e2e, package installed by the agent's package module.

THE OUTCOME, one per (family, package), exhaustive:
  verified        installed, the shipped file is there, the checker exited 0 on it
  rejected        the checker exited non-zero on the shipped file, accepted a broken one, changed the host, or did
                  not exit at all (a daemon start) — the reason is kept; not written
  no-shipped-file installed, but the package does not ship the file (sssd.conf) — nothing to verify against
  not-installed   the package manager refused (not in this family's repos, or a dependency failed)
  infra-error     the probe itself could not run a step
--write adds every `verified` entry to package_validators.json (source "verified by hand <date> (probe_checkers …)")
and never removes or overwrites an existing entry.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures as cf
import json
import os
import shlex
import subprocess
import time
import uuid
from pathlib import Path

from bossman.tools import qualify_packages as Q
from bossman.tools import validators_store as VS

CONFIGS = Q._CONFIGS
VALIDATORS = CONFIGS / "package_validators.json"
RESULTS = CONFIGS / "checker_probe_results.json"
IMAGES = Path(os.environ.get("AGENTIC_BATCH_LOG_DIR", str(Path.home() / ".local/state/agentic-batches"))) \
    / "pkg-e2e-images.json"
CTX = os.environ.get("PKG_E2E_CONTEXT", "bossman-dev")
NS = "pkg-e2e-probe"
PROXY = os.environ.get("YOLOMAN_HTTP_PROXY", "http://proxy.example.internal:80")
ENV = {**os.environ, "NO_PROXY": "192.168.49.0/24,localhost,127.0.0.1", "no_proxy": "192.168.49.0/24,localhost,127.0.0.1"}

#: (family, package to install, checker with {path}, the file it is run on). The plan's list (E3); a checker whose
#: binary lives in another package names that package (cups' cupsd is in cups-daemon on Debian).
CANDIDATES: list[tuple[str, str, str, str]] = [
    ("debian", "bind9", "named-checkconf {path}", "/etc/bind/named.conf"),
    ("debian", "postfix", 'postfix -c "$(dirname {path})" check', "/etc/postfix/main.cf"),
    ("debian", "haproxy", "haproxy -c -f {path}", "/etc/haproxy/haproxy.cfg"),
    ("debian", "squid", "squid -k parse -f {path}", "/etc/squid/squid.conf"),
    ("debian", "openssh-server", "sshd -t -f {path}", "/etc/ssh/sshd_config"),
    ("debian", "apache2", "apache2ctl -t -f {path}", "/etc/apache2/apache2.conf"),
    ("debian", "nginx", "nginx -t -c {path}", "/etc/nginx/nginx.conf"),
    ("debian", "dovecot-core", "doveconf -n -c {path}", "/etc/dovecot/dovecot.conf"),
    ("debian", "opendmarc", "opendmarc -n -c {path}", "/etc/opendmarc.conf"),
    ("debian", "keepalived", "keepalived -t -f {path}", "/etc/keepalived/keepalived.conf"),
    ("debian", "isc-dhcp-server", "dhcpd -t -cf {path}", "/etc/dhcp/dhcpd.conf"),
    ("debian", "prometheus", "promtool check config {path}", "/etc/prometheus/prometheus.yml"),
    ("debian", "cups-daemon", "cupsd -t -c {path}", "/etc/cups/cupsd.conf"),
    ("debian", "cups", "cupsd -t -c {path}", "/etc/cups/cupsd.conf"),   # the role installs cups; cupsd comes with it
    ("debian", "miredo", "miredo-checkconf {path}", "/etc/miredo/miredo.conf"),
    ("debian", "sssd-common", "sssctl config-check -c {path}", "/etc/sssd/sssd.conf"),
    ("debian", "kea-dhcp4-server", "kea-dhcp4 -t {path}", "/etc/kea/kea-dhcp4.conf"),
    ("redhat", "kea", "kea-dhcp4 -t {path}", "/etc/kea/kea-dhcp4.conf"),
    ("redhat", "bind", "named-checkconf {path}", "/etc/named.conf"),
    ("redhat", "postfix", 'postfix -c "$(dirname {path})" check', "/etc/postfix/main.cf"),
    ("redhat", "haproxy", "haproxy -c -f {path}", "/etc/haproxy/haproxy.cfg"),
    ("redhat", "squid", "squid -k parse -f {path}", "/etc/squid/squid.conf"),
    # EL creates the host keys on sshd's first start (sshd-keygen), not at install: plain `sshd -t` said "no hostkeys
    # available" on a fresh host. A throwaway key passed with -h tests the FILE and leaves the host as it was.
    ("redhat", "openssh-server",
     'k=$(mktemp -u /tmp/hk.XXXXXX); ssh-keygen -q -t ed25519 -N "" -f "$k" && sshd -t -f {path} -h "$k"; '
     'rc=$?; rm -f "$k" "$k.pub"; exit $rc', "/etc/ssh/sshd_config"),
    ("redhat", "httpd", "httpd -t -f {path}", "/etc/httpd/conf/httpd.conf"),
    ("redhat", "nginx", "nginx -t -c {path}", "/etc/nginx/nginx.conf"),
    ("redhat", "dovecot", "doveconf -n -c {path}", "/etc/dovecot/dovecot.conf"),
    ("redhat", "opendmarc", "opendmarc -n -c {path}", "/etc/opendmarc.conf"),
    ("redhat", "keepalived", "keepalived -t -f {path}", "/etc/keepalived/keepalived.conf"),
    ("redhat", "dhcp-server", "dhcpd -t -cf {path}", "/etc/dhcp/dhcpd.conf"),
    ("redhat", "cups", "cupsd -t -c {path}", "/etc/cups/cupsd.conf"),
    ("redhat", "sssd-common", "sssctl config-check -c {path}", "/etc/sssd/sssd.conf"),
]


#: State a service creates on a real host at its FIRST START (ExecStartPre and friends), which a freshly installed
#: test host lacks — without it a genuine checker refuses the shipped file for a reason that says nothing about the
#: file. Measured: `unbound-checkconf` failed on "auto-trust-anchor-file /var/lib/unbound/root.key does not exist"
#: (2026-10-17); unbound.service creates it in ExecStartPre (unbound-helper) before the daemon starts. Curated, one line each.
FIRST_START: dict[tuple[str, str], str] = {
    # unbound.service's own ExecStartPre (unbound-anchor needs the root servers, which a test pod cannot reach)
    ("debian", "unbound"): "/usr/libexec/unbound-helper root_trust_anchor_update; test -s /var/lib/unbound/root.key "
                           "|| cp /usr/share/dns/root.key /var/lib/unbound/root.key",
}

#: How long a checker may run before it counts as a service start, not a check.
CHECK_SECONDS = 60


def kubectl(*argv: str, timeout: int = 300) -> subprocess.CompletedProcess:
    # errors="replace": a checker's output is whatever the program prints — one wrote Latin-1 (byte 0xd6) and the
    # whole probe run died on UnicodeDecodeError, 39 verdicts unwritten (2026-10-16).
    return subprocess.run(["kubectl", "--context", CTX, "-n", NS, *argv], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout, env=ENV)


def image(family: str) -> str:
    tags = json.loads(IMAGES.read_text())
    return tags[family]   # keys as deploy/test-images/build.sh writes them: debian, redhat (+ *_host)


def probe(family: str, pkg: str, check: str, path: str) -> dict:
    t0 = time.monotonic()
    res = _probe(family, pkg, check, path)
    res["seconds"] = round(time.monotonic() - t0, 1)
    return res


def _probe(family: str, pkg: str, check: str, path: str) -> dict:
    name = f"probe-{family[:3]}-{uuid.uuid4().hex[:6]}"
    out: dict = {"family": family, "package": pkg, "check_cmd": check, "path": path,
                 "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    try:
        r = kubectl("run", name, f"--image={image(family)}", "--image-pull-policy=Never", "--restart=Never",
                    f"--env=http_proxy={PROXY}", f"--env=https_proxy={PROXY}",
                    "--env=no_proxy=192.168.49.0/24,.example.internal,localhost", "--command", "--", "sleep", "3600")
        if r.returncode != 0:
            return {**out, "outcome": "infra-error", "reason": r.stderr[-300:]}
        r = kubectl("wait", "--for=condition=Ready", f"pod/{name}", "--timeout=180s", timeout=240)
        if r.returncode != 0:
            return {**out, "outcome": "infra-error", "reason": "pod not ready: " + r.stderr[-300:]}
        r = kubectl("exec", name, "--", "/usr/bin/agentic-mcpd", "run-module", "package", "--json",
                    json.dumps({"name": [pkg], "state": "present"}), timeout=1500)
        if r.returncode != 0:
            return {**out, "outcome": "not-installed", "reason": (r.stderr or r.stdout)[-600:]}
        r = kubectl("exec", name, "--", "test", "-f", path)
        if r.returncode != 0:
            return {**out, "outcome": "no-shipped-file", "reason": f"{pkg} installed, {path} is not there"}
        if (family, pkg) in FIRST_START:
            r = kubectl("exec", name, "--", "sh", "-c", FIRST_START[(family, pkg)], timeout=180)
            out["first_start"] = {"cmd": FIRST_START[(family, pkg)], "rc": r.returncode}
        # THE COUNTER-PROBE FIRST: a checker must REFUSE a broken file. A command that accepts anything is not a
        # checker — the miner proposed `adduser --conf {path} --debug user` (creates a user, exit 0) and server
        # binaries that simply start. Broken first, because such a command changes the host: run second, adduser
        # failed on "user exists" and looked like a checker. The shipped file plus a line no syntax accepts.
        bad = "/tmp/probe-broken" + (Path(path).suffix or ".conf")
        kubectl("exec", name, "--", "sh", "-c", f"cp {shlex.quote(path)} {bad} && "
                f"printf '\\n@@@ not a valid line {{{{ ]] <<<\\n' >> {bad}")
        # A CHECK ENDS. Run under `timeout` inside the pod: rc 124 means the command was still running after
        # CHECK_SECONDS — a daemon start (bearerbox, kresd -n, tlshd), not a check. Before, kubectl's own timeout
        # fired and 11 such commands were filed as infra-error, a fact about the probe instead of the command.
        timed = lambda c: f"timeout {CHECK_SECONDS} sh -c {shlex.quote(c)}"  # noqa: E731
        rb = kubectl("exec", name, "--", "sh", "-c", timed(check.replace("{path}", shlex.quote(bad))),
                     timeout=CHECK_SECONDS + 60)
        out["counter_probe"] = {"rc": rb.returncode, "output": (rb.stderr + rb.stdout)[-300:]}
        if rb.returncode == 124:
            return {**out, "outcome": "rejected",
                    "reason": f"does not exit within {CHECK_SECONDS} s on a broken file — it starts the service, "
                              "it does not check a file"}
        cmd = check.replace("{path}", shlex.quote(path))
        kubectl("exec", name, "--", "sh", "-c", "sleep 1; touch /tmp/probe-marker; sleep 1")
        r = kubectl("exec", name, "--", "sh", "-c", timed(cmd), timeout=CHECK_SECONDS + 60)
        out["check"] = {"rc": r.returncode, "output": (r.stderr + r.stdout)[-800:]}
        if r.returncode == 124:
            return {**out, "outcome": "rejected",
                    "reason": f"does not exit within {CHECK_SECONDS} s on the shipped file — it starts the service, "
                              "it does not check a file"}
        # NO SIDE EFFECTS: the role check runs this on real hosts after every apply. adduser's "check" passed both
        # probes — and created a user each time; apt-mirror's ran the mirror into /var/spool. Any file it changed under
        # /etc, /var/lib, /var/spool, /srv, /opt, /root or /home disqualifies it.
        ch = kubectl("exec", name, "--", "sh", "-c", "find /etc /var/lib /var/spool /srv /opt /root /home -xdev "
                     "-newer /tmp/probe-marker -type f 2>/dev/null | grep -vE '^/var/lib/(dpkg|apt|dnf|rpm|systemd|logrotate)/' | head -5")
        changed = [x for x in ch.stdout.split() if x]
        if changed and rb.returncode != 0 and r.returncode == 0:
            out["outcome"] = "rejected"
            out["reason"] = "changes the host (files written: " + ", ".join(changed) + ") — not a side-effect-free checker"
            return out
        if rb.returncode == 0:
            out["outcome"] = "rejected"
            out["reason"] = "accepts a deliberately broken file — not a configuration checker"
        else:
            out["outcome"] = "verified" if r.returncode == 0 else "rejected"
        return out
    except subprocess.TimeoutExpired as e:
        return {**out, "outcome": "infra-error", "reason": f"timeout: {e.cmd[-1] if e.cmd else ''}"[:200]}
    finally:
        kubectl("delete", "pod", name, "--wait=false", "--grace-period=0", "--force")


def mined_candidates() -> list[tuple[str, str, str, str]]:
    """(family, package, check_cmd, path) for every mined (unverified) checker with a check command, the path being
    the file the worklist routes for that package."""
    val = json.loads(VALIDATORS.read_text())
    work = json.loads((CONFIGS / "package_e2e_worklist.json").read_text()).get("families", {})
    out = []
    for fam, entries in val.items():
        rows = work.get(fam) or {}
        for pkg, e in entries.items():
            if str(e.get("source") or "").startswith("verified") or e.get("status") == "rejected":
                continue
            path = (rows.get(pkg) or {}).get("path") if isinstance(rows, dict) else None
            if e.get("check_cmd") and path:
                out.append((fam, pkg, e["check_cmd"], path))
    return sorted(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="")
    ap.add_argument("--family", choices=("debian", "redhat"), action="append")
    ap.add_argument("--parallel", type=int, default=3)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--mined", action="store_true",
                    help="probe the checkers the LLM miner wrote (no `source: verified …`) instead of the fixed list; "
                         "with --write a verified one is marked verified, a rejected one `status: rejected`")
    args = ap.parse_args()
    candidates = CANDIDATES
    if args.mined:
        candidates = mined_candidates()
        print(f"{len(candidates)} mined checker(s) with a check command and a known path")
    todo = [c for c in candidates if (not args.family or c[0] in args.family)
            and (not args.only or c[1] in {s.strip() for s in args.only.split(",")})]
    subprocess.run(["kubectl", "--context", CTX, "create", "ns", NS], capture_output=True, env=ENV)
    results = json.loads(RESULTS.read_text()) if RESULTS.is_file() else {}
    with cf.ThreadPoolExecutor(args.parallel) as ex:
        for res in ex.map(lambda c: probe(*c), todo):
            results[f"{res['family']}|{res['package']}"] = res
            print(f"{res['family']}/{res['package']}: {res['outcome']} ({res.get('seconds')}s)"
                  + (f" — {res['check']['output'].strip().splitlines()[-1][:160]}" if res.get("check") and
                     res["outcome"] != "verified" and res["check"]["output"].strip() else "")
                  + (f" — {res['reason'][-160:]}" if res.get("reason") else ""), flush=True)
    RESULTS.write_text(json.dumps(dict(sorted(results.items())), indent=1) + "\n")
    if args.write and args.mined:
        day = time.strftime("%Y-%m-%d")
        marked = collections.Counter()

        def mark(val: dict) -> None:
            # Into the CURRENT file, under the lock (validators_store) — the miner may have written meanwhile.
            for fam, pkg, cmd, _path in todo:
                res = results.get(f"{fam}|{pkg}") or {}
                e = val.get(fam, {}).get(pkg)
                if e is None or not res or e.get("check_cmd") != cmd:
                    continue        # gone, not probed, or re-mined since: the verdict is about another command
                _mark(e, res, fam, day, marked)

        VS.update(mark, VALIDATORS)
        print(f"package_validators.json: {dict(marked)}")
        return 0
    if args.write:
        day = time.strftime("%Y-%m-%d")
        added = 0

        def add(val: dict) -> None:
            nonlocal added
            for res in results.values():
                if res["outcome"] != "verified":
                    continue
                fam = val.setdefault(res["family"], {})
                if res["package"] in fam:
                    continue
                fam[res["package"]] = {
                    "check_cmd": res["check_cmd"], "daemon_cmd": None,
                    "evidence": f"the command accepted the file the package ships ({res['path']}) on a fresh "
                                f"{res['family']} test host",
                    "source": f"verified by hand {day} (probe_checkers, against the shipped file in the package-e2e "
                              "test image)",
                    "status": "ok", "version": "val-v1"}   # the miner's version: it does not redo a current entry
                added += 1

        VS.update(add, VALIDATORS)
        print(f"package_validators.json: {added} checker(s) added")
    return 0


def _mark(e: dict, res: dict, fam: str, day: str, marked: collections.Counter) -> None:
    if res["outcome"] == "verified":
        e["source"] = f"verified by probe {day} (probe_checkers --mined, against the shipped file)"
        # Only the CHECK command was probed; the miner's daemon command is still a hypothesis.
        if e.get("daemon_cmd"):
            e["daemon_cmd_mined"], e["daemon_cmd"] = e["daemon_cmd"], None
        marked["verified"] += 1
    elif res["outcome"] in ("rejected", "no-shipped-file", "not-installed"):
        e["status"] = "rejected"
        e["rejected"] = f"{res['outcome']} on a fresh {fam} test host ({day}): " + \
            ((res.get("check") or {}).get("output") or res.get("reason") or "")[-300:]
        marked[res["outcome"]] += 1


if __name__ == "__main__":
    raise SystemExit(main())
