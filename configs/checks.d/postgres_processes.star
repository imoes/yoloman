def _find_postgres_pids(ctx):
    res = ctx.run(["ps", "ax", "-o", "pid=,command="], mutates=False)
    if res.rc != 0:
        return []
    pids = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        pid_str = parts[0]
        cmd = parts[1]
        if ("postgres" in cmd or "postmaster" in cmd) and pid_str.isdigit():
            pids.append(int(pid_str))
    return pids

def main(ctx, params):
    # Probe for postgres installation — two common entry points
    which_postgres = ctx.run(["which", "postgres"], mutates=False)
    which_pgctl = ctx.run(["which", "pg_ctlcluster"], mutates=False)
    pg_installed = (which_postgres.rc == 0) or (which_pgctl.rc == 0)

    pids = _find_postgres_pids(ctx)

    if params.get("_discover"):
        if not pg_installed and not pids:
            return {
                "changed": False,
                "msg": "postgres not installed",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered postgres process count service",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["count"]},
            ]},
        }

    count = len(pids)
    if count == 0:
        return {
            "changed": False,
            "msg": "0",
            "data": {
                "state": "CRIT",
                "metrics": {"count": 0},
                "details": "No postgres process matched",
            },
        }

    pid_list = ", ".join([str(p) for p in sorted(pids)])
    return {
        "changed": False,
        "msg": str(count),
        "data": {
            "state": "OK",
            "metrics": {"count": count},
            "details": "PIDs: " + pid_list,
        },
    }