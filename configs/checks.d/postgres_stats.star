TS_EXPRS = {
    "VACUUM": "COALESCE(EXTRACT(EPOCH FROM last_vacuum)::bigint, -1)",
    "ANALYZE": "COALESCE(EXTRACT(EPOCH FROM last_analyze)::bigint, -1)",
}
LEVEL_PARAMS = {"VACUUM": "last_vacuum", "ANALYZE": "last_analyze"}

def _format_duration(seconds):
    if seconds < 60:
        return "%d seconds" % seconds
    if seconds < 3600:
        return "%d minutes" % (seconds // 60)
    if seconds < 86400:
        return "%d hours" % (seconds // 3600)
    return "%d days" % (seconds // 86400)

def _psql_argv(params, dbname):
    host = params.get("host", "")
    port = str(params.get("port", 5432))
    user = params.get("user", "postgres")
    argv = ["psql"]
    if host:
        argv = argv + ["-h", host]
    argv = argv + ["-p", port, "-U", user, "-d", dbname, "-t", "-A", "-F;"]
    return argv

def main(ctx, params):
    if params.get("_discover"):
        argv = _psql_argv(params, "postgres") + [
            "-c",
            "SELECT datname FROM pg_database WHERE datallowconn = true AND datname NOT IN ('template0','template1') ORDER BY datname",
        ]
        res = ctx.run(argv, mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "psql failed: " + res.stderr,
                    "data": {"discovery": []}}
        databases = [l.strip() for l in res.stdout.splitlines() if l.strip()]
        items = []
        for db in databases:
            for op in ["VACUUM", "ANALYZE"]:
                items.append({
                    "item": op + " " + db,
                    "params": {},
                    "metrics": ["oldest_%s_age" % op.lower(), "never_checked_count"],
                })
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    parts = item.split(" ", 1)
    if len(parts) != 2 or parts[0] not in TS_EXPRS:
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item_type = parts[0]
    database = parts[1]
    ts_expr = TS_EXPRS[item_type]
    level_param = LEVEL_PARAMS[item_type]

    now_res = ctx.run(["date", "+%s"], mutates=False)
    now_str = now_res.stdout.strip()
    now = int(now_str) if now_res.rc == 0 and now_str.isdigit() else 0

    query = "SELECT schemaname, tablename, %s FROM pg_stat_user_tables ORDER BY tablename" % ts_expr
    argv = _psql_argv(params, database) + ["-c", query]
    res = ctx.run(argv, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "psql failed for %s: %s" % (database, res.stderr),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oldest_time = None
    oldest_name = ""
    never_checked = []

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        fields = line.split(";")
        if len(fields) < 3:
            continue
        sname = fields[0]
        tname = fields[1]
        ts_str = fields[2].strip()
        if sname == "pg_catalog":
            continue
        ts = int(ts_str) if ts_str else -1
        if ts == -1:
            never_checked.append(tname)
        elif oldest_time == None or ts < oldest_time:
            oldest_time = ts
            oldest_name = tname

    verb = item_type.lower().strip("e") + "ed"
    state = "OK"
    msg_parts = []
    metrics = {}

    if oldest_time != None:
        age = now - oldest_time
        metrics["oldest_%s_age" % item_type.lower()] = age
        levels = params.get(level_param, None)
        warn = None
        crit = None
        if levels != None:
            warn = levels[0]
            crit = levels[1]
        if crit != None and age >= crit:
            state = "CRIT"
        elif warn != None and age >= warn:
            state = "WARN"
        msg_parts.append("Table: %s, Not %s for: %s" % (oldest_name, verb, _format_duration(age)))

    nc_count = len(never_checked)
    metrics["never_checked_count"] = nc_count
    if nc_count > 0:
        cutoff = " (first 3 shown)" if nc_count > 3 else ""
        shown = " / ".join(never_checked[:3])
        msg_parts.append("%d tables never %s: %s%s" % (nc_count, verb, shown, cutoff))
    else:
        msg_parts.append("No never %s tables" % verb)

    if oldest_time == None and nc_count == 0:
        return {"changed": False, "msg": "No user tables found in " + database,
                "data": {"state": "UNKNOWN", "metrics": metrics, "details": ""}}

    return {"changed": False, "msg": "; ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}