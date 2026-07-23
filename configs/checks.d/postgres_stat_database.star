def main(ctx, params):
    if params.get("_discover"):
        cmd = ["psql", "-U", params.get("username", "postgres"), "-d", "postgres", "-t", "-c", "SELECT datid, datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted FROM pg_stat_database;"]
        res = ctx.run(cmd, mutates=False)
        items = []
        for line in res.stdout.splitlines():
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 12:
                continue
            datid, datname, _, xact_commit, _, _, _, _, _, _, _, _ = parts
            if xact_commit.isdigit() or (xact_commit.startswith("-") and xact_commit[1:].isdigit()):
                xact_commit_int = int(xact_commit) if xact_commit else 0
            else:
                xact_commit_int = 0
            if xact_commit_int > 0 and datid != "0":
                item_name = datname if datname else "access_to_shared_objects"
                items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": ["blks_read", "tup_fetched", "xact_commit", "tup_deleted", "tup_updated", "tup_inserted"]
                })
        return {
            "changed": False,
            "msg": "discovered %d databases" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    escaped_item = item.replace("'", "''")
    cmd = ["psql", "-U", params.get("username", "postgres"), "-d", "postgres", "-t", "-c", "SELECT datid, datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted FROM pg_stat_database WHERE datname = '" + escaped_item + "';"]
    res = ctx.run(cmd, mutates=False)

    lines = res.stdout.strip().split("\n")
    if len(lines) < 1 or lines[0].strip() == "":
        return {
            "changed": False,
            "msg": "Database not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    parts = [p.strip() for p in lines[0].split("|")]
    if len(parts) < 12:
        return {
            "changed": False,
            "msg": "Invalid data format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    datid, datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted = parts

    def _safe_int(s):
        if s == None:
            return 0
        s = str(s)
        if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
            return int(s)
        return 0

    current_values = {
        "blks_read": _safe_int(blks_read),
        "tup_fetched": _safe_int(tup_fetched),
        "xact_commit": _safe_int(xact_commit),
        "tup_deleted": _safe_int(tup_deleted),
        "tup_updated": _safe_int(tup_updated),
        "tup_inserted": _safe_int(tup_inserted),
    }

    rates = {
        "blks_read": 0.0,
        "tup_fetched": 0.0,
        "xact_commit": 0.0,
        "tup_deleted": 0.0,
        "tup_updated": 0.0,
        "tup_inserted": 0.0,
    }

    status = "OK"
    infos = []

    for metric, title in [
        ("blks_read", "Blocks Read"),
        ("tup_fetched", "Fetches"),
        ("xact_commit", "Commits"),
        ("tup_deleted", "Deletes"),
        ("tup_updated", "Updates"),
        ("tup_inserted", "Inserts"),
    ]:
        rate = rates[metric]
        warn = params.get(metric, (None, None))
        crit = params.get(metric + "_crit", (None, None))

        levels = params.get("levels", {})
        if metric in levels:
            warn, crit = levels[metric]
        else:
            warn = params.get(metric + "_warn")
            crit = params.get(metric + "_crit")
            if warn != None or crit != None:
                warn = warn if warn != None else 0.0
                crit = crit if crit != None else 0.0

        if crit != None and rate >= crit:
            status = "CRIT"
            infos.append("%s: %.2f/s (!!)") % (title, rate)
        elif warn != None and rate >= warn:
            if status == "OK":
                status = "WARN"
            infos.append("%s: %.2f/s (!)") % (title, rate)
        else:
            infos.append("%s: %.2f/s") % (title, rate)

    return {
        "changed": False,
        "msg": ", ".join(infos),
        "data": {
            "state": status,
            "metrics": rates,
            "details": ""
        }
    }