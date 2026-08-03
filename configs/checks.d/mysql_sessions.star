# MySQL Sessions — Checkmk checkmk.mysql_sessions translation
# Read-only Starlark check module for the yolo-man agent.

MYSQL_DEFAULTS = {
    "running": (20, 40),
    "total": (100, 400),
    "connections": (3, 5),
}


def _mysql_status(ctx):
    """Run SHOW GLOBAL STATUS against MySQL; return dict or None."""
    res = ctx.run(["mysql", "--batch", "--raw", "-e", "SHOW GLOBAL STATUS"], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    status = {}
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            status[parts[0]] = parts[1]
    return status


def _to_int(value):
    """Parse int safely; 0 on failure."""
    s = str(value).strip()
    if s.isdigit():
        return int(s)
    neg = s.startswith("-") and s[1:].isdigit() if len(s) > 1 else False
    if neg:
        return int(s)
    return 0


def _grade(value, levels, upper=True):
    """Grade a value against (warn, crit) levels. Returns state string."""
    state = "OK"
    if levels != None:
        warn = levels[0]
        crit = levels[1]
        if upper:
            if value >= crit:
                state = "CRIT"
            elif value >= warn:
                state = "WARN"
        else:
            if value <= crit:
                state = "CRIT"
            elif value <= warn:
                state = "WARN"
    return state


def main(ctx, params):
    if params.get("_discover"):
        status = _mysql_status(ctx)
        if status == None:
            return {"changed": False, "msg": "mysql not installed",
                    "data": {"discovery": []}}
        if "Threads_connected" in status and "Threads_running" in status and "Connections" in status:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "mysql", "params": {"running": [20, 40], "total": [100, 400], "connections": [3, 5]}, "metrics": ["total_sessions", "running_sessions", "connect_rate"]}]}}
        return {"changed": False, "msg": "no mysql session data", "data": {"discovery": []}}

    item = params.get("item", "mysql")
    status = _mysql_status(ctx)
    if status == None:
        return {"changed": False, "msg": "mysql not installed or no access",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    needed = ["Threads_connected", "Threads_running", "Connections"]
    missing = [k for k in needed if k not in status]
    if len(missing) > 0:
        return {"changed": False, "msg": "missing keys: %s" % ", ".join(missing),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_sessions = _to_int(status["Threads_connected"])
    running_sessions = _to_int(status["Threads_running"])
    connections_total = _to_int(status["Connections"])

    uptime = 0
    if "Uptime" in status:
        uptime = _to_int(status["Uptime"])
    if uptime > 1:
        connect_rate = float(connections_total) / float(uptime)
    else:
        connect_rate = 0.0

    metrics = {"total_sessions": total_sessions, "running_sessions": running_sessions, "connect_rate": connect_rate}

    running_levels = params.get("running", MYSQL_DEFAULTS["running"])
    total_levels = params.get("total", MYSQL_DEFAULTS["total"])
    conn_levels = params.get("connections", MYSQL_DEFAULTS["connections"])

    states = []
    states.append(_grade(running_sessions, running_levels, upper=True))
    states.append(_grade(total_sessions, total_levels, upper=True))
    states.append(_grade(connect_rate, conn_levels, upper=True))
    if "CRIT" in states:
        state = "CRIT"
    else:
        if "WARN" in states:
            state = "WARN"
        else:
            state = "OK"

    msgs = []
    msgs.append("total %d" % total_sessions)
    msgs.append("running %d" % running_sessions)
    msgs.append("connects %f/s" % connect_rate)
    msg = ", ".join(msgs)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": msg}}