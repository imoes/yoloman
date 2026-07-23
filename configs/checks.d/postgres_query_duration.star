SQL_QUERIES = (
    "SELECT usename, COALESCE(client_addr::text,''), state, " +
    "GREATEST(0, COALESCE(FLOOR(EXTRACT(EPOCH FROM (now()-query_start)))::bigint,0))::text, " +
    "pid::text, REPLACE(LEFT(COALESCE(query,''),200),chr(10),' ') " +
    "FROM pg_stat_activity " +
    "WHERE state NOT IN ('idle') AND state IS NOT NULL AND pid != pg_backend_pid() " +
    "ORDER BY query_start ASC"
)


def main(ctx, params):
    host = params.get("host", "localhost")
    port = str(params.get("port", 5432))
    user = params.get("user", "postgres")
    dbname = params.get("dbname", "postgres")
    warn = params.get("warn", None)
    crit = params.get("crit", None)

    if params.get("_discover"):
        res = ctx.run(
            ["psql", "-h", host, "-p", port, "-U", user, "-d", dbname,
             "-t", "-A", "-c", "SELECT 1"],
            mutates=False, ok_codes=[0, 1, 2, 3],
        )
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["longest_query_seconds"]},
                ]}}

    res = ctx.run(
        ["psql", "-h", host, "-p", port, "-U", user, "-d", dbname,
         "-t", "-A", "-F", "|", "-c", SQL_QUERIES],
        mutates=False, ok_codes=[0, 1, 2, 3],
    )

    if res.rc != 0:
        return {"changed": False, "msg": "Cannot connect to PostgreSQL",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr.strip()}}

    lines = [l for l in res.stdout.splitlines() if l.strip()]

    if not lines:
        return {"changed": False, "msg": "No queries running",
                "data": {"state": "OK", "metrics": {"longest_query_seconds": 0}, "details": ""}}

    best_sec = -1
    best_row = None
    for line in lines:
        cols = line.split("|")
        if len(cols) < 5:
            continue
        sec = int(cols[3]) if cols[3].isdigit() else 0
        if sec > best_sec:
            best_sec = sec
            best_row = cols

    if best_row == None:
        return {"changed": False, "msg": "No queries running",
                "data": {"state": "OK", "metrics": {"longest_query_seconds": 0}, "details": ""}}

    usename = best_row[0]
    client_addr = best_row[1]
    state_val = best_row[2]
    seconds = best_sec
    pid = best_row[4]
    qtext = best_row[5] if len(best_row) > 5 else ""

    parts = ["Longest query: %d seconds" % seconds]
    if usename:
        parts.append("Username: %s" % usename)
    if client_addr:
        parts.append("Client: %s" % client_addr)
    if state_val.lower() != "active":
        parts.append("Query state: %s" % state_val)
    parts.append("PID: %s" % pid)
    if qtext:
        parts.append("Query: %s" % qtext)

    msg = ", ".join(parts)

    check_state = "OK"
    if crit != None and seconds >= crit:
        check_state = "CRIT"
    elif warn != None and seconds >= warn:
        check_state = "WARN"

    return {"changed": False, "msg": msg,
            "data": {"state": check_state, "metrics": {"longest_query_seconds": seconds}, "details": ""}}