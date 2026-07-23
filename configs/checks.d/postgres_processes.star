def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 PostgreSQL process count service",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["process_count"]},
            ]},
        }

    res = ctx.run(["ps", "-eo", "pid,comm"], mutates=False, ok_codes=[0])

    seen = {}
    pids = []

    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        pid_str = parts[0]
        comm = parts[1]
        if not pid_str.isdigit():
            continue
        if comm == "postgres" or comm == "postmaster":
            pid = int(pid_str)
            if pid not in seen:
                seen[pid] = True
                pids.append(pid)

    count = len(pids)

    if count == 0:
        return {
            "changed": False,
            "msg": "0",
            "data": {
                "state": "CRIT",
                "metrics": {"process_count": 0},
                "details": "No process matched",
            },
        }

    pid_strs = [str(p) for p in pids]
    return {
        "changed": False,
        "msg": str(count),
        "data": {
            "state": "OK",
            "metrics": {"process_count": count},
            "details": "PIDs: " + ", ".join(pid_strs),
        },
    }