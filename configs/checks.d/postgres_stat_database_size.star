def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "psql", "-U", "postgres", "-d", "postgres", "-t", "-c",
            "SELECT datid, datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted FROM pg_stat_database;"
        ], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            fields = line.strip().split("|")
            if len(fields) < 12:
                continue
            datid, datname = fields[0], fields[1]
            xact_commit_str = fields[3]
            xact_commit = int(xact_commit_str) if xact_commit_str.isdigit() else 0
            if datid != "0" and xact_commit > 0:
                name = datname if datname != "" else "access_to_shared_objects"
                out.append({
                    "item": name,
                    "params": {},
                    "metrics": ["size"]
                })
        return {
            "changed": False,
            "msg": "discovered %d databases" % len(out),
            "data": {"discovery": out}
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no database item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    safe_item = item.replace("'", "''")
    res = ctx.run([
        "psql", "-U", "postgres", "-d", "postgres", "-t", "-c",
        "SELECT pg_database_size('%s')" % safe_item
    ], mutates=False)
    size_str = res.stdout.strip()
    size = int(size_str) if size_str.isdigit() else 0

    levels = params.get("database_size")
    warn, crit = None, None
    if levels != None:
        warn = levels[0]
        crit = levels[1]

    state = "OK"
    if size == 0 and size_str == "":
        state = "WARN"
        msg = "Database size is not available."
    elif crit != None and size >= crit:
        state = "CRIT"
        msg = "Size: " + str(size) + "B (crit at " + str(crit) + "B)"
    elif warn != None and size >= warn:
        state = "WARN"
        msg = "Size: " + str(size) + "B (warn at " + str(warn) + "B)"
    else:
        msg = "Size: " + str(size) + "B"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"size": size},
            "details": ""
        }
    }