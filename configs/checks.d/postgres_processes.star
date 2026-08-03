def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["pgrep", "-x", "postgres"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "pgrep not installed",
                    "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "no postgres processes found",
                    "data": {"discovery": []}}
        pids = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped != "" and stripped.isdigit():
                pids.append(int(stripped))
        if len(pids) == 0:
            return {"changed": False, "msg": "no postgres processes found",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered PostgreSQL Process Count service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["process_count"]}
                ]}}
    res = ctx.run(["pgrep", "-x", "postgres"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "pgrep not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "no postgres processes found",
                "data": {"state": "CRIT", "metrics": {"process_count": 0},
                         "details": "No process matched"}}
    count = 0
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped != "" and stripped.isdigit():
            count = count + 1
    if count == 0:
        return {"changed": False, "msg": "no postgres processes found",
                "data": {"state": "CRIT", "metrics": {"process_count": 0},
                         "details": "No process matched"}}
    return {"changed": False,
            "msg": "%d" % count,
            "data": {"state": "OK", "metrics": {"process_count": count},
                     "details": "PIDs"}}