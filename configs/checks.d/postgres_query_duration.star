def _to_float(s):
    if s == None or s == "":
        return 0.0
    neg = False
    t = s
    if t.startswith("-"):
        neg = True
        t = t[1:]
    if "." in t:
        parts = t.split(".")
        int_part = parts[0]
        frac_part = parts[1]
        if int_part == "":
            int_part = "0"
        ok = True
        for c in int_part:
            if not c.isdigit():
                ok = False
                break
        if ok:
            for c in frac_part:
                if not c.isdigit():
                    ok = False
                    break
        if ok:
            result = float(s)
            if neg:
                result = -result
            return result
    else:
        ok = True
        for c in t:
            if not c.isdigit():
                ok = False
                break
        if ok:
            result = float(s)
            if neg:
                result = -result
            return result
    return 0.0

def main(ctx, params):
    discover = params.get("_discover", False)
    item = params.get("item", "")

    probe = ctx.run(["psql", "--version"], mutates=False)
    if probe.rc == 127:
        if discover:
            return {"changed": False, "msg": "psql not installed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "psql not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sql = "SELECT datname, datid, usename, client_addr, state, EXTRACT(EPOCH FROM (now() - query_start)) AS seconds, pid, current_query FROM pg_stat_activity WHERE state = 'active' AND current_query IS NOT NULL AND query_start IS NOT NULL"
    res = ctx.run(["psql", "-At", "-F", ";", "-c", sql], mutates=False)
    if res.rc != 0:
        if discover:
            return {"changed": False, "msg": "psql query failed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "psql query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    db_res = ctx.run(["psql", "-At", "-c", "SELECT datname FROM pg_database WHERE datistemplate = false"], mutates=False)
    db_names = []
    if db_res.rc == 0:
        for line in db_res.stdout.split("\n"):
            if line.strip() != "":
                db_names.append(line.strip())

    if discover:
        discovery = []
        for db in db_names:
            discovery.append({"item": db, "params": {}, "metrics": ["seconds"]})
        return {"changed": False, "msg": "discovered %d databases" % len(discovery),
                "data": {"discovery": discovery}}

    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cols = ["datname", "datid", "usename", "client_addr", "state", "seconds", "pid", "current_query"]
    rows = []
    for line in res.stdout.split("\n"):
        if line.strip() == "":
            continue
        parts = line.split(";")
        if len(parts) < 8:
            continue
        row = {}
        for idx in range(len(cols)):
            row[cols[idx]] = parts[idx] if idx < len(parts) else ""
        rows.append(row)

    item_rows = [r for r in rows if r.get("datname") == item]

    if len(db_names) > 0 and item not in db_names:
        return {"changed": False, "msg": "no such database: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if len(item_rows) == 0:
        return {"changed": False, "msg": "No queries running",
                "data": {"state": "OK", "metrics": {"seconds": 0.0}, "details": ""}}

    longest = item_rows[0]
    longest_secs = _to_float(longest.get("seconds", "0"))
    for r in item_rows:
        secs_val = _to_float(r.get("seconds", "0"))
        if secs_val > longest_secs:
            longest_secs = secs_val
            longest = r

    secs_str = longest.get("seconds", "0")
    usename = longest.get("usename", "")
    client_addr = longest.get("client_addr", "")
    qstate = longest.get("state", "")
    pid = longest.get("pid", "")
    current_query = longest.get("current_query", "")

    msg = "Longest query: %s seconds" % secs_str
    if usename:
        msg = msg + ", Username: " + usename
    if client_addr:
        msg = msg + ", Client: " + client_addr
    if qstate and qstate.lower() != "active":
        msg = msg + ", Query state: " + qstate
    msg = msg + ", PID: " + pid
    msg = msg + ", Query: " + current_query

    details = "Longest running query in database %s: %s seconds\n" % (item, secs_str)
    details = details + "Details:\n"
    for r in item_rows:
        details = details + "  PID=%s User=%s State=%s Seconds=%s Query=%s\n" % (
            r.get("pid", ""),
            r.get("usename", ""),
            r.get("state", ""),
            r.get("seconds", ""),
            r.get("current_query", ""),
        )

    return {"changed": False, "msg": msg,
            "data": {"state": "OK", "metrics": {"seconds": longest_secs}, "details": details}}