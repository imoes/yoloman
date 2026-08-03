def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["rpm", "-q", "TIVsm"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "no TSM client/server found on host",
                "data": {"discovery": [], "host_labels": {}},
            }
        out = []
        out.append({
            "item": "",
            "params": {"warn": 300, "crit": 600},
            "metrics": ["sessions"],
        })
        return {
            "changed": False,
            "msg": "discovered %d item" % len(out),
            "data": {"discovery": out, "host_labels": {}},
        }
    if ctx.file_exists("/opt/tivoli/tsm/client/api/bin64/dsm.opt") == False:
        return {
            "changed": False,
            "msg": "no TSM client found on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    res = ctx.run(
        ["/usr/bin/dsmstat", "-s"],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "TSM client not responding: %s" % res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    warn = 300
    crit = 600
    count = 0
    state = "OK"
    lines = res.stdout.splitlines()
    for line in lines:
        f = line.split()
        if len(f) < 2:
            continue
        proc_state = f[-2] if len(f) >= 2 else ""
        wait = f[-1] if len(f) >= 1 else ""
        if proc_state not in ("RecvW", "MediaW"):
            continue
        wait_seconds = int(wait) if wait.isdigit() else 0
        if wait_seconds >= crit:
            state = "CRIT"
            count = count + 1
        elif wait_seconds >= warn:
            if state != "CRIT":
                state = "WARN"
            count = count + 1
    return {
        "changed": False,
        "msg": "%d sessions too long in RecvW or MediaW state" % count,
        "data": {"state": state, "metrics": {"sessions": count}, "details": ""},
    }