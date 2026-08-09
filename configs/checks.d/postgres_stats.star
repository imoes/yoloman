def _parse_dbs(raw_text):
    return {}


def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["psql", "-At", "-c", "SELECT datname FROM pg_database WHERE datistemplate = false;"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "psql not available or query failed", "data": {"discovery": [], "host_labels": {}}}
        databases = []
        for line in res.stdout.splitlines():
            db = line.strip()
            if db:
                databases.append(db)
        discovery = []
        for db in databases:
            discovery.append({"item": "VACUUM " + db, "params": {}, "metrics": ["age_seconds", "stale_seconds"]})
            discovery.append({"item": "ANALYZE " + db, "params": {}, "metrics": ["age_seconds", "stale_seconds"]})
        total = len(discovery)
        msg = "discovered %d items" % total
        return {"changed": False, "msg": msg, "data": {"discovery": discovery}}

    item = params.get("item", "")
    if not item or " " not in item:
        return {"changed": False, "msg": "no postgres_stats item selected", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = item.split(" ", 1)
    item_type = parts[0]
    database = parts[1]

    sql = "SELECT schemaname, tablename, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze FROM pg_stat_user_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1, 2;"
    res = ctx.run(["psql", "-At", "-c", sql], mutates=False)

    now_res = ctx.run(["date", "+%s"])
    now = 0
    if now_res.rc == 0:
        s = now_res.stdout.strip()
        if s.isdigit():
            now = int(s)

    if res.rc != 0:
        if res.rc == 127:
            return {"changed": False, "msg": "psql not installed; cannot check PostgreSQL statistics", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "psql query failed: " + res.stderr, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    tables = []
    for line in res.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) < 6:
            continue
        tables.append({"sname": fields[0], "tname": fields[1], "last_vacuum": fields[2], "last_autovacuum": fields[3], "last_analyze": fields[4], "last_autoanalyze": fields[5]})

    if not tables:
        return {"changed": False, "msg": "no such database or no statistics available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stats_field = item_type[0].lower() + "time"
    text = item_type.lower()
    if text.endswith("e"):
        text = text[:-1]
    text = text + "ed"

    times_and_names = []
    for table in tables:
        if table["sname"] == "pg_catalog":
            continue
        raw_time = table.get(stats_field, "")
        tval = -1
        if raw_time and raw_time != "None" and raw_time != "0":
            tval = raw_time.split(".")[0]
            tval = tval.replace("-", "")
            if tval and tval.isdigit():
                tval = int(tval)
            else:
                tval = -1
        times_and_names.append((tval, table["tname"]))

    oldest_element = None
    for t, n in times_and_names:
        if t != -1:
            if oldest_element == None or t < oldest_element[0]:
                oldest_element = (t, n)

    never_checked = [n for t, n in times_and_names if t == -1]

    metrics = {}
    details_parts = []

    if oldest_element:
        oldest_time = oldest_element[0]
        oldest_name = oldest_element[1]
        age = now - oldest_time if now > 0 else 0
        metrics["age_seconds"] = age
        details_parts.append("Table: " + oldest_name + " (age: " + str(age) + "s)")

    if never_checked:
        metrics["stale_seconds"] = len(never_checked)
        details_parts.append(str(len(never_checked)) + " tables were never " + text + ": " + " / ".join(never_checked))

    levels_upper = params.get("never_analyze_vacuum", (0, 1000 * 365 * 24 * 3600))
    warn = levels_upper[0]
    crit = levels_upper[1]

    state = "OK"
    if oldest_element and now > 0:
        age = now - oldest_element[0]
        if age >= crit:
            state = "CRIT"
        elif age >= warn:
            state = "WARN"

    if never_checked and now > 0:
        count = len(never_checked)
        if count >= crit:
            state = "CRIT"
        elif count >= warn:
            state = "WARN"

    msg = "No tables found"
    if details_parts:
        msg = "; ".join(details_parts)
    details = "\n".join(details_parts)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}