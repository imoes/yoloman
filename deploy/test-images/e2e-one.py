#!/usr/bin/env python3
"""One package, one fresh pod: install it, configure it the way a rule or the wizard would, and let the package
itself judge the result. The pod-side half of bossman/bossman/tools/package_e2e.py.

The spec comes in as JSON in $E2E_SPEC; the result goes out as ONE line `E2E_RESULT {...}` on stdout, which the
runner reads from `kubectl logs` — no `kubectl exec` (the kubectl module refuses it on purpose).

The configuration is written by the AGENT's own modules (`agentic-mcpd run-module template_render | config`),
the same Go code a Bossman apply runs — not by a re-implementation in this script.

THE OUTCOME IS EXHAUSTIVE — exactly one of:
  pass                 configured, and the package's own checker and/or a foreground start accepted it
  pass-unverified      configured, but neither a checker nor a daemon command is known (reason given)
  install-failed       the package manager refused (stderr tail attached)
  target-missing       installed, but the file the route names is not there
  render-failed        the agent module could not write the configuration
  validate-failed      the package's checker rejected the written file
  daemon-failed        the daemon, started in the foreground with the written file, exited non-zero
  no-config-confirmed  route no-config: the installed package indeed has no file under /etc
  no-config-refuted    route no-config: it does — the classification was wrong
  install-only         route wizard, but the role names no template: it installs and configures nothing
  infra-error          this script itself could not run a step (never a fact about the package)
"""

from __future__ import annotations

import json
import os
import shlex
import signal
import subprocess
import sys
import time

AGENT = "/usr/bin/agentic-mcpd"


def sh(argv, timeout=900, **kw):
    t0 = time.monotonic()
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, **kw)
        return p.returncode, p.stdout, p.stderr, round(time.monotonic() - t0, 1)
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s", round(time.monotonic() - t0, 1)


def tail(text: str, n: int = 1500) -> str:
    return text[-n:] if text else ""


def module(name: str, params: dict, dry_run: bool = False, timeout: int = 120) -> tuple[bool, dict, str]:
    argv = [AGENT, "run-module", name, "--json", json.dumps(params)]
    if dry_run:
        argv.append("--dry-run")
    rc, out, err, _ = sh(argv, timeout=timeout)
    try:
        data = json.loads(out.strip().splitlines()[-1]) if out.strip() else {}
    except ValueError:
        data = {}
    return rc == 0, data, tail(err or out, 800)


def install(family: str, pkg: str) -> tuple[int, str, float]:
    """Through the AGENT's package module — the path a managed host takes. It used to be apt-get/dnf called here
    with capture_output: hylafax-server's postinst loops on "Area code []?" forever and the pod died buffering it
    (no result line). The agent bounds a command's output and stops a runaway with its last lines as the reason."""
    t0 = time.monotonic()
    ok, data, err = module("package", {"name": pkg.split(), "state": "present"}, timeout=1200)
    return (0 if ok else 1), tail(err or json.dumps(data)), round(time.monotonic() - t0, 1)


def etc_files(family: str, pkg: str) -> list[str]:
    argv = ["dpkg", "-L", pkg] if family == "debian" else ["rpm", "-ql", pkg]
    _, out, _, _ = sh(argv, timeout=60)
    return [p for p in out.splitlines() if p.startswith("/etc/") and os.path.isfile(p)]


def run_check(cmd: str | None, path: str) -> dict | None:
    if not cmd:
        return None
    rc, out, err, dt = sh(["sh", "-c", cmd.replace("{path}", shlex.quote(path))], timeout=120)
    return {"cmd": cmd, "rc": rc, "output": tail(err + out, 1200), "seconds": dt}


def run_daemon(cmd: str | None, path: str, seconds: int = 10) -> dict | None:
    """Start in the FOREGROUND for `seconds`. Still running = it accepted its config; a non-zero exit before
    then = it did not. Exit 0 before the deadline is recorded as such (some daemons only validate and leave)."""
    if not cmd:
        return None
    # Its own process group, and the GROUP is killed: killing only the `sh` left nginx holding the output pipe,
    # and the pod waited on it forever.
    p = subprocess.Popen(["sh", "-c", "exec " + cmd.replace("{path}", shlex.quote(path))],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=seconds)
        return {"cmd": cmd, "alive": False, "rc": p.returncode, "output": tail(out, 1200)}
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        try:
            out, _ = p.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            out = ""
        return {"cmd": cmd, "alive": True, "rc": None, "output": tail(out, 600)}


def same_lines(a: str, b: str, active_only: bool = False) -> bool:
    """Same non-blank lines. `active_only` drops comment lines first — the enrich stage adds documentation comments on
    purpose, and the question for the HOST is whether the settings are the same (template_invariants.ok_semantic)."""
    def norm(t: str) -> list[str]:
        lines = [ln.rstrip() for ln in t.split("\n") if ln.strip()]
        if active_only:
            # Whitespace-collapsed too: a re-indented setting is the same setting (template_invariants.ok_semantic).
            lines = [" ".join(ln.split()) for ln in lines if not ln.lstrip().startswith(("#", ";", "//"))]
        return lines
    return norm(a) == norm(b)


def main() -> int:
    spec = json.loads(os.environ["E2E_SPEC"])
    family, pkg, route = spec["family"], spec["package"], spec["route"]
    path = spec.get("target_path") or ""
    res: dict = {"family": family, "package": pkg, "route": route, "path": path}

    # The role's packages, as the wizard installs them (samba's testparm is in another package than samba-common).
    rc, log, dt = install(family, " ".join(spec.get("packages") or [pkg]))
    res["install_seconds"] = dt
    if rc != 0:
        res.update(outcome="install-failed", reason=log)
        return emit(res)

    if route == "no-config":
        files = etc_files(family, pkg)
        # The worklist's own rule for "not configuration" (executed scripts, noise), passed in by the runner — one
        # rule, not a second opinion in the pod. Measured: all 256 "refuted" of the first run were init.d,
        # profile.d, cron.daily and hook scripts the worklist had rightly not counted.
        import re as _re
        skip = [_re.compile(p) for p in spec.get("not_config") or []]
        config = [f for f in files if not any(rx.search(f) for rx in skip)]
        res.update(outcome="no-config-refuted" if config else "no-config-confirmed",
                   etc_files=files[:20], config_files=config[:20])
        return emit(res)

    if not path and route == "wizard":
        # A catalog role with no file on this family (restic, wireguard: "installed, not configured") — the install
        # was proven above; there is nothing to configure, which is a fact about the catalog, not a missing target.
        res.update(outcome="install-only", reason="the role configures no file on this family: it installs, it does not configure")
        return emit(res)
    if not path:
        res.update(outcome="target-missing", reason="the route names no configuration file",
                   etc_files=etc_files(family, pkg)[:20])
        return emit(res)
    # A file the package does not ship (fail2ban's jail.local, sssd.conf) is CREATED by the configuration — as the
    # wizard does. Then there is nothing to reproduce; the checker still judges what was written.
    if not os.path.isfile(path):
        # A path recorded for another RELEASE (java-latest: java-25-openjdk recorded, the mirror ships 27): the same
        # file of the installed version, found the way the agent's codec lookup does — every digit run alike, and only
        # when exactly one installed file matches.
        import re as _re
        vl = lambda p: _re.sub(r"[0-9]+", "#", p)   # noqa: E731
        argv = ["dpkg", "-L", pkg] if family == "debian" else ["rpm", "-ql", pkg]
        _, out, _, _ = sh(argv, timeout=60)
        same = [p for p in out.splitlines() if vl(p) == vl(path) and os.path.isfile(p)]
        if len(same) == 1:
            res["path_resolved_from"] = path
            path = res["path"] = same[0]
    res["target_shipped"] = os.path.isfile(path)
    shipped = open(path, errors="replace").read() if res["target_shipped"] else ""

    if route == "wizard" and not spec.get("template"):
        # The role installs the package and offers no configuration at all — a fact about the catalog, named.
        res.update(outcome="install-only", reason="the wizard role names no template: it installs, it does not configure")
        return emit(res)
    if route in ("wizard", "rule-template"):
        tpl = f"/configs/config_templates/{spec['template']}/template.j2"
        ok, data, err = module("template_render", {"template_path": tpl, "dest": path,
                                                   "values": spec.get("defaults") or {}}, dry_run=True)
        if not ok:
            res.update(outcome="render-failed", step="render-defaults", reason=err)
            return emit(res)
        rendered = ((data.get("data") or {}).get("rendered")) or ""
        if res["target_shipped"]:
            res["defaults_reproduce_shipped"] = same_lines(rendered, shipped)
            res["defaults_reproduce_settings"] = same_lines(rendered, shipped, active_only=True)
        ok, data, err = module("template_render", {"template_path": tpl, "dest": path,
                                                   "values": {**(spec.get("defaults") or {}),
                                                              **(spec.get("variant") or {})}})
        if not ok:
            res.update(outcome="render-failed", step="render-variant", reason=err)
            return emit(res)
        res["variant"] = spec.get("variant") or {}
    elif route == "rule-codec":
        codec = spec.get("codec") or {}
        base = {"path": path, "format": codec.get("format") or "keyvalue"}
        for k in ("separator", "comment"):
            if codec.get(k):
                base[k] = codec[k]
        ok, data, err = module("config", base)
        if not ok:
            res.update(outcome="render-failed", step="codec-read", reason=err)
            return emit(res)
        change = spec.get("codec_change") or {}
        if change:
            ok, data, err = module("config", {**base, "values": change, "manage": "merge"})
            if not ok:
                res.update(outcome="render-failed", step="codec-write", reason=err)
                return emit(res)
            ok, data, err = module("config", base)
            values = (data.get("data") or {}).get("config") or {}
            res["codec_roundtrip"] = all(str(values.get(k)) == str(v) for k, v in change.items()) if ok else False
        res["variant"] = change
    else:
        res.update(outcome="infra-error", reason=f"unknown route {route!r}")
        return emit(res)

    check = run_check(spec.get("check_cmd"), path)
    daemon = run_daemon(spec.get("daemon_cmd"), path)
    res["check"], res["daemon"] = check, daemon
    if check and check["rc"] != 0:
        res["outcome"] = "validate-failed"
    elif daemon and not daemon["alive"] and daemon["rc"] not in (0, None):
        res["outcome"] = "daemon-failed"
    elif check or daemon:
        res["outcome"] = "pass"
    else:
        res.update(outcome="pass-unverified", reason="no checker and no foreground daemon command known")
    return emit(res)


def emit(res: dict) -> int:
    print("E2E_RESULT " + json.dumps(res), flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 — a broken step of THIS script is infra, not the package
        print("E2E_RESULT " + json.dumps({"outcome": "infra-error", "reason": f"{type(exc).__name__}: {exc}"}))
        sys.exit(0)
