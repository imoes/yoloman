def main(ctx, params):
    if params.get("_discover"):
        return {"changed": False, "msg": "active check (assign with parameters)", "data": {"discovery": []}}

    host = params.get("host") or ""
    dbms = params.get("dbms") or "postgres"
    db_name = params.get("db_name") or ""
    user = params.get("user") or ""
    password = params.get("password") or ""
    sql = params.get("sql") or ""
    port = params.get("port")
    use_procedure = params.get("use_procedure") or False
    procedure_input = params.get("procedure_input")
    timeout_s = int(params.get("timeout_s") or 30)
    perfdata_col = params.get("perfdata")
    text_tmpl = params.get("text")
    warn_high = params.get("warn_high")
    crit_high = params.get("crit_high")
    warn_low = params.get("warn_low")
    crit_low = params.get("crit_low")

    stmt = sql
    if use_procedure:
        if procedure_input != None:
            stmt = "CALL %s(%s)" % (sql, procedure_input)
        else:
            stmt = "CALL %s()" % sql

    if dbms == "mysql":
        argv = ["mysql", "-h", host, "-u", user, "-p" + password, "-D", db_name,
                "-N", "-B", "--connect-timeout=%d" % timeout_s]
        if port != None:
            argv = argv + ["-P", "%d" % int(port)]
        argv = argv + ["-e", stmt]
    elif dbms == "postgres":
        if port != None:
            conn = "postgresql://%s:%s@%s:%d/%s" % (user, password, host, int(port), db_name)
        else:
            conn = "postgresql://%s:%s@%s/%s" % (user, password, host, db_name)
        argv = ["psql", conn, "-t", "-A", "-c", stmt]
    elif dbms == "mssql":
        if port != None:
            srv = "%s,%d" % (host, int(port))
        else:
            srv = host
        argv = ["sqlcmd", "-S", srv, "-U", user, "-P", password, "-d", db_name,
                "-h", "-1", "-W", "-s", "|", "-Q", stmt]
    else:
        return {"changed": False, "msg": "UNKNOWN", "data": {
            "state": "UNKNOWN", "metrics": {},
            "details": "Unsupported DBMS: %s" % dbms}}

    result = ctx.run(argv, ok_codes=[0, 1, 2])

    if result.rc != 0:
        return {"changed": False, "msg": "CRIT", "data": {
            "state": "CRIT", "metrics": {},
            "details": "DB error (rc=%d): %s" % (result.rc, (result.stderr or "").strip())}}

    output = (result.stdout or "").strip()
    rows = [l.strip() for l in output.split("\n") if l.strip()]
    if not rows:
        return {"changed": False, "msg": "UNKNOWN", "data": {
            "state": "UNKNOWN", "metrics": {},
            "details": "Empty query result"}}

    row = rows[0]
    if "|" in row:
        cols = row.split("|")
    elif "\t" in row:
        cols = row.split("\t")
    else:
        cols = row.split()

    col1 = cols[0].strip() if cols else "0"
    col2 = cols[1].strip() if len(cols) > 1 else ""
    col3 = cols[2].strip() if len(cols) > 2 else ""

    metrics = {}
    use_levels = warn_high != None or crit_high != None or warn_low != None or crit_low != None

    if use_levels:
        val = float(col1 or "0")
        state = "OK"
        problems = []

        if crit_high != None and val >= crit_high:
            state = "CRIT"
            problems.append("value %d >= crit_high %d" % (int(val), int(crit_high)))
        elif warn_high != None and val >= warn_high:
            state = "WARN"
            problems.append("value %d >= warn_high %d" % (int(val), int(warn_high)))

        if crit_low != None and val <= crit_low:
            state = "CRIT"
            problems.append("value %d <= crit_low %d" % (int(val), int(crit_low)))
        elif warn_low != None and val <= warn_low:
            if state != "CRIT":
                state = "WARN"
            problems.append("value %d <= warn_low %d" % (int(val), int(warn_low)))

        if perfdata_col:
            metrics[perfdata_col] = val

        detail = col2
        if text_tmpl:
            detail = text_tmpl
        if problems:
            detail = detail + " | " + "; ".join(problems)

        return {"changed": False, "msg": state, "data": {
            "state": state, "metrics": metrics, "details": detail}}

    status_int = int(col1) if col1 else 0
    if status_int == 0:
        state = "OK"
    elif status_int == 1:
        state = "WARN"
    elif status_int == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    if col3 and perfdata_col:
        mval_s = col3.split(";")[0].strip()
        if "=" in mval_s:
            kv = mval_s.split("=", 1)
            metrics[kv[0].strip()] = float(kv[1].strip() or "0")
        else:
            metrics[perfdata_col] = float(mval_s or "0")

    detail = col2
    if text_tmpl:
        detail = text_tmpl

    return {"changed": False, "msg": state, "data": {
        "state": state, "metrics": metrics, "details": detail}}
