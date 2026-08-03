def _to_int(s):
    s = s.strip()
    if s.lstrip("-").isdigit():
        return int(s)
    return None

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["vmstat", "1", "2"], mutates=False)
        if res.rc == 0 and res.stdout:
            return {
                "changed": False,
                "msg": "discovered CPU utilization",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {},
                            "metrics": [
                                "cpu_user",
                                "cpu_system",
                                "cpu_idle",
                                "cpu_iowait",
                                "cpu_iowait_percent",
                            ],
                        }
                    ]
                },
            }
        return {
            "changed": False,
            "msg": "no CPU data available",
            "data": {"discovery": []},
        }

    res = ctx.run(["vmstat", "1", "2"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "no CPU data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    lines = [l for l in res.stdout.splitlines() if l.strip()]
    if len(lines) < 3:
        return {
            "changed": False,
            "msg": "no CPU data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    header = lines[-2].split()
    data = lines[-1].split()
    if len(header) != len(data):
        return {
            "changed": False,
            "msg": "no CPU data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    idx = {}
    for i, h in enumerate(header):
        idx[h] = i

    def col(name):
        pos = idx.get(name)
        if pos == None or pos >= len(data):
            return None
        return _to_int(data[pos])

    user = col("us")
    system = col("sy")
    idle = col("id")
    iowait = col("wa")

    if user == None or system == None or idle == None or iowait == None:
        return {
            "changed": False,
            "msg": "no CPU data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    total = user + system + idle + iowait
    if total <= 0:
        total = 1

    user_p = user * 100.0 / total
    system_p = system * 100.0 / total
    idle_p = idle * 100.0 / total
    iowait_p = iowait * 100.0 / total

    warn = params.get("iowait", {}).get("warn", 0) if params.get("iowait") else 0
    crit = params.get("iowait", {}).get("crit", 0) if params.get("iowait") else 0
    if params.get("iowait_levels"):
        wl = params.get("iowait_levels")
        if type(wl) == "list" and len(wl) >= 2:
            warn = wl[0]
            crit = wl[1]

    state = "OK"
    if crit and iowait_p >= crit:
        state = "CRIT"
    elif warn and iowait_p >= warn:
        state = "WARN"

    msg = "User: %f%%, System: %f%%, Idle: %f%%, I/O wait: %f%%" % (
        user_p, system_p, idle_p, iowait_p
    )
    if iowait_p > 0 and (warn or crit):
        msg = msg + " - iowait %s" % state

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "cpu_user": user_p,
                "cpu_system": system_p,
                "cpu_idle": idle_p,
                "cpu_iowait": iowait_p,
                "cpu_iowait_percent": iowait_p,
            },
            "details": "",
        },
    }