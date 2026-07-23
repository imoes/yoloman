# db2_counters: deadlocks and lockwaits per DB2 database (cumulative snapshot values)

COUNTER_LABELS = {
    "Deadlocks detected": "deadlocks",
    "Lock waits": "lockwaits",
}

def _db2_run(ctx, instance, cmd_str):
    if instance != None and instance != "":
        return ctx.run(["su", "-", instance, "-c", "db2 " + cmd_str], mutates=False)
    return ctx.run(["db2"] + cmd_str.split(), mutates=False)

def _parse_snapshot(output):
    counters = {}
    for line in output.splitlines():
        stripped = line.strip()
        for label, key in COUNTER_LABELS.items():
            if stripped.startswith(label) and "=" in stripped:
                parts = stripped.split("=", 1)
                val = parts[1].strip()
                if val.isdigit():
                    counters[key] = int(val)
    return counters

def _apply_levels(state, value, levels, label, msgs):
    if levels == None:
        msgs.append("%s: %d" % (label, value))
        return state
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        msgs.append("%s: %d (>= %d!!)" % (label, value, crit))
        return "CRIT"
    if value >= warn:
        msgs.append("%s: %d (>= %d!)" % (label, value, warn))
        if state == "OK":
            return "WARN"
        return state
    msgs.append("%s: %d" % (label, value))
    return state

def main(ctx, params):
    instance = params.get("instance", None)

    if params.get("_discover"):
        res = _db2_run(ctx, instance, "list active databases")
        databases = []
        if res.rc == 0:
            for line in res.stdout.splitlines():
                stripped = line.strip()
                if stripped.startswith("Database name") and "=" in stripped:
                    parts = stripped.split("=", 1)
                    dbname = parts[1].strip()
                    if dbname:
                        databases.append({
                            "item": dbname,
                            "params": {},
                            "metrics": ["deadlocks", "lockwaits"],
                        })
        return {
            "changed": False,
            "msg": "discovered %d databases" % len(databases),
            "data": {"discovery": databases},
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no database item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = _db2_run(ctx, instance, "get snapshot for database on " + item)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "db2 snapshot failed for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr[:200]},
        }

    counters = _parse_snapshot(res.stdout)
    if not counters:
        return {
            "changed": False,
            "msg": "no counter data for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    deadlocks = counters.get("deadlocks", 0)
    lockwaits = counters.get("lockwaits", 0)

    deadlock_levels = params.get("deadlocks", None)
    lockwait_levels = params.get("lockwaits", None)

    state = "OK"
    msgs = []
    state = _apply_levels(state, deadlocks, deadlock_levels, "Deadlocks", msgs)
    state = _apply_levels(state, lockwaits, lockwait_levels, "Lockwaits", msgs)

    return {
        "changed": False,
        "msg": ", ".join(msgs),
        "data": {
            "state": state,
            "metrics": {"deadlocks": deadlocks, "lockwaits": lockwaits},
            "details": "",
        },
    }