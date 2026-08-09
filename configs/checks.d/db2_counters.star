def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["db2level"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "db2 not installed", "data": {"discovery": []}}
        dbs = _discover_dbs(ctx)
        if not dbs:
            return {"changed": False, "msg": "no db2 databases found", "data": {"discovery": []}}
        discovery = []
        for db in dbs:
            discovery.append({"item": db, "params": {}, "metrics": ["deadlocks", "lockwaits"]})
        return {"changed": False, "msg": "discovered %d db2 databases" % len(discovery), "data": {"discovery": discovery}}
    item = params.get("item", "")
    return _check_db2_counters(ctx, params, item)


def _discover_dbs(ctx):
    dbs = []
    res = ctx.run(["db2", "list", "database", "directory"], mutates=False)
    if res.rc != 0:
        return dbs
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Database name"):
            parts = stripped.split("=")
            if len(parts) >= 2:
                name = parts[1].strip()
                if name and name not in dbs:
                    dbs.append(name)
    return dbs


def _check_db2_counters(ctx, params, item):
    metrics = {}
    state = "OK"
    msg_parts = []
    has_data = False
    for counter in ["deadlocks", "lockwaits"]:
        rate = _get_counter_rate(ctx, item, counter)
        if rate == None:
            continue
        has_data = True
        metrics[counter] = rate
        warn = params.get(counter + "_warn", None)
        crit = params.get(counter + "_crit", None)
        if warn != None and rate >= float(warn):
            if crit != None and rate >= float(crit):
                state = "CRIT"
            else:
                if state != "CRIT":
                    state = "WARN"
        msg_parts.append(counter + ": %f/s" % rate)
    if not has_data:
        return {"changed": False, "msg": "no db2 database found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": ", ".join(msg_parts), "data": {"state": state, "metrics": metrics, "details": ""}}


def _get_counter_rate(ctx, item, counter):
    res = ctx.run(["db2", "list", "monitor", "reports", "database", item], mutates=False)
    if res.rc != 0:
        return None
    if counter == "deadlocks":
        col = "deadlocks"
    else:
        col = "lockwaits_total"
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(col):
            parts = stripped.split()
            for i, p in enumerate(parts):
                if p == col and i + 1 < len(parts):
                    val = parts[i + 1]
                    if val.replace(".", "").isdigit() or (val.startswith("-") and val.replace(".", "").replace("-", "").isdigit()):
                        return float(val)
                    return None
    return None