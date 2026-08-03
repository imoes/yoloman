def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["psql", "-t", "-A", "-c",
                       "SELECT datname FROM pg_stat_database WHERE xact_commit > 0 ORDER BY datname"],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "psql not available", "data": {"discovery": []}}
        out = []
        for raw in res.stdout.splitlines():
            name = raw.strip()
            if name:
                m = ["blks_read", "tup_fetched", "xact_commit",
                     "tup_deleted", "tup_updated", "tup_inserted"]
                out.append({"item": name, "params": {}, "metrics": m})
        return {"changed": False, "msg": "discovered %d databases" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    query = "SELECT datname, blks_read, tup_fetched, xact_commit, " + \
            "tup_deleted, tup_updated, tup_inserted FROM pg_stat_database " + \
            "WHERE datname = '%s'" % item
    res = ctx.run(["psql", "-t", "-A", "-c", query], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no such database: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    rows = res.stdout.strip().splitlines()
    if not rows:
        return {"changed": False, "msg": "no such database: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parts = rows[0].split("|")
    if len(parts) < 7:
        return {"changed": False, "msg": "bad data for database: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def to_int(v):
        vs = (v or "").strip()
        return int(vs) if vs.isdigit() else 0

    blks_read = to_int(parts[1])
    tup_fetched = to_int(parts[2])
    xact_commit = to_int(parts[3])
    tup_deleted = to_int(parts[4])
    tup_updated = to_int(parts[5])
    tup_inserted = to_int(parts[6])

    metrics = {"blks_read": blks_read, "tup_fetched": tup_fetched,
               "xact_commit": xact_commit, "tup_deleted": tup_deleted,
               "tup_updated": tup_updated, "tup_inserted": tup_inserted}

    infos = ["Blocks Read: %d" % blks_read, "Fetches: %d" % tup_fetched,
             "Commits: %d" % xact_commit, "Deletes: %d" % tup_deleted,
             "Updates: %d" % tup_updated, "Inserts: %d" % tup_inserted]

    return {"changed": False, "msg": ", ".join(infos),
            "data": {"state": "OK", "metrics": metrics, "details": ""}}