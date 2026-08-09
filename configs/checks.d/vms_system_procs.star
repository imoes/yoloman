def main(ctx, params):
    res = ctx.run(["cat", "/proc/stat"], mutates=False)
    procs = 0
    for line in res.stdout.splitlines():
        if line.startswith("processes "):
            parts = line.split()
            if len(parts) >= 2:
                procs = int(parts[1])
            break

    # Checkmk default: levels_upper=None
    levels_upper = params.get("levels_upper")

    # Compute state
    state = "OK"
    if levels_upper != None:
        warn, crit = levels_upper
        if procs >= crit:
            state = "CRIT"
        elif procs >= warn:
            state = "WARN"

    msg = "Processes: %d" % procs

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"procs": procs},
            "details": "",
        },
    }
