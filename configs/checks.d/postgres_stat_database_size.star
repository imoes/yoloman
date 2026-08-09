def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["psql", "-Atq", "-c",
                       "SELECT datid, datname, xact_commit, blks_read, tup_fetched, tup_inserted, tup_updated, tup_deleted, pg_database_size(datname) AS datsize FROM pg_stat_database JOIN pg_database USING (datname)"],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "psql not available", "data": {"discovery": []}}
        out = []
        for line in res.stdout.splitlines():
            f = line.split("|")
            if len(f) < 10:
                continue
            if f[0] == "datid" or not f[0] or f[0] == "0":
                continue
            xact_commit = int(f[2]) if f[2].strip().isdigit() else 0
            if xact_commit <= 0:
                continue
            db_name = f[1] if f[1] else "access_to_shared_objects"
            out.append({"item": db_name, "params": {"database_size": None},
                        "metrics": ["size"]})
        return {"changed": False, "msg": "discovered %d databases" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["psql", "-Atq", "-c",
                   "SELECT datid, datname, xact_commit, blks_read, tup_fetched, tup_inserted, tup_updated, tup_deleted, pg_database_size(datname) AS datsize FROM pg_stat_database JOIN pg_database USING (datname)"],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "psql query failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found = None
    for line in res.stdout.splitlines():
        f = line.split("|")
        if len(f) < 10:
            continue
        if f[0] == "datid" or not f[0] or f[0] == "0":
            continue
        db_name = f[1] if f[1] else "access_to_shared_objects"
        if db_name == item:
            found = f
            break

    if found == None:
        return {"changed": False, "msg": "Database not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    datsize = found[9]
    if datsize in ["", None, "0"]:
        return {"changed": False, "msg": "Database size is not available",
                "data": {"state": "WARN", "metrics": {}, "details": ""}}

    size = int(datsize)
    levels = params.get("database_size", None)
    state = "OK"
    if levels != None:
        warn, crit = levels[0], levels[1]
        if size >= crit:
            state = "CRIT"
        elif size >= warn:
            state = "WARN"

    return {"changed": False,
            "msg": "%s Size: %s" % (item, _render_bytes(size)),
            "data": {"state": state, "metrics": {"size": size}, "details": ""}}

def _render_bytes(n):
    units = ["B", "kB", "MB", "GB", "TB", "PB"]
    val = float(n)
    i = 0
    while val >= 1024 and i < len(units) - 1:
        val = val / 1024.0
        i = i + 1
    return "%f %s" % (val, units[i])