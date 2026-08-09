# Copyright (C) 2025 Checkmk GmbH - License: GNU General Public License v2
# Translated to read-only Starlark for the yolo-man agent.

def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx)

    return _check(ctx, params)


def _podman_available(ctx):
    res = ctx.run(["podman", "version", "--format", "{{.Version}}"], mutates=False)
    if res.rc == 127:
        return False, "podman is not installed"
    if res.rc != 0:
        return False, "podman version check failed: " + res.stderr.strip()
    return True, res.stdout.strip()


def _discover(ctx):
    ok, _ = _podman_available(ctx)
    if not ok:
        return {"changed": False, "msg": "no podman available",
                "data": {"discovery": []}}

    return {"changed": False, "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "",
                 "params": {},
                 "metrics": ["podman_container_restarts_total",
                             "podman_container_restarts_last_hour"]},
            ]}}


def _check(ctx, params):
    ok, vmsg = _podman_available(ctx)
    if not ok:
        return {"changed": False, "msg": vmsg,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(
        ["podman", "ps", "-a", "--format", "{{.RestartCount}}"],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False,
                "msg": "podman ps failed: " + res.stderr.strip(),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total = 0
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        total += int(line)

    warn_total = params.get("restarts_total_warn")
    crit_total = params.get("restarts_total_crit")
    state_total = _grade_upper(total, warn_total, crit_total)

    metrics = {"podman_container_restarts_total": total}

    return {"changed": False,
            "msg": "Total restarts: %d" % total,
            "data": {"state": state_total, "metrics": metrics, "details": ""}}


def _grade_upper(value, warn, crit):
    if crit != None and _ge(value, crit):
        return "CRIT"
    if warn != None and _ge(value, warn):
        return "WARN"
    return "OK"


def _ge(a, b):
    return (a > b) or (a == b)