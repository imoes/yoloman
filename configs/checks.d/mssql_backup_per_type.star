MAP_BACKUP_TYPES = {
    "D": "database",
    "I": "database diff",
    "L": "log",
    "F": "file or filegroup",
    "G": "file diff",
    "P": "partial",
    "Q": "partial diff",
    "-": "unspecific",
}

BACKUP_SQL = "SET NOCOUNT ON; SELECT @@SERVERNAME, database_name, ISNULL(CONVERT(VARCHAR(19), MAX(backup_finish_date), 120), 'never'), type, ISNULL(DATEDIFF(SECOND, MAX(backup_finish_date), GETDATE()), -1) FROM msdb.dbo.backupset GROUP BY database_name, type ORDER BY database_name, type"

def _build_argv(params, query):
    server = params.get("server", "localhost")
    instance = params.get("instance", "")
    port = str(params.get("port", 1433))
    username = params.get("username", "")
    password = params.get("password", "")
    if instance:
        target = server + "\\" + instance
    elif port != "1433":
        target = server + "," + port
    else:
        target = server
    argv = ["sqlcmd", "-S", target, "-h", "-1", "-W", "-s", "|", "-Q", query]
    if username:
        argv = argv + ["-U", username, "-P", password]
    else:
        argv = argv + ["-E"]
    return argv

def _format_timespan(secs):
    secs = int(secs)
    if secs < 60:
        return "%d seconds" % secs
    if secs < 3600:
        return "%d minutes" % (secs // 60)
    if secs < 86400:
        return "%f hours" % (float(secs) / 3600.0)
    return "%f days" % (float(secs) / 86400.0)

def _parse_rows(output):
    rows = []
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split("|")
        if len(parts) < 5:
            continue
        servername = parts[0].strip()
        db_name = parts[1].strip()
        last_ts = parts[2].strip()
        btype_code = parts[3].strip()
        age_str = parts[4].strip()
        if not servername or not db_name or not btype_code:
            continue
        check_digits = age_str.lstrip("-")
        if not check_digits or not check_digits.isdigit():
            continue
        btype = MAP_BACKUP_TYPES.get(btype_code, "unspecific")
        item_name = "%s %s %s" % (servername, db_name, btype.title())
        rows.append({
            "item": item_name,
            "last_ts": last_ts,
            "age": int(age_str),
            "has_backup": last_ts != "never",
        })
    return rows

def main(ctx, params):
    if params.get("_discover"):
        argv = _build_argv(params, BACKUP_SQL)
        res = ctx.run(argv, mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "query failed: %s" % res.stderr.strip(),
                "data": {"discovery": []},
            }
        rows = _parse_rows(res.stdout)
        discovery = [
            {"item": r["item"], "params": {}, "metrics": ["backup_age"]}
            for r in rows
        ]
        return {
            "changed": False,
            "msg": "discovered %d backup types" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    argv = _build_argv(params, BACKUP_SQL)
    res = ctx.run(argv, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "query failed: %s" % res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = _parse_rows(res.stdout)
    matched = None
    for r in rows:
        if r["item"] == item:
            matched = r
            break

    if matched == None:
        return {
            "changed": False,
            "msg": "item not found - connection problem or backup type gone?",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not matched["has_backup"]:
        return {
            "changed": False,
            "msg": "No backup found",
            "data": {"state": "WARN", "metrics": {}, "details": ""},
        }

    age = matched["age"]
    last_ts = matched["last_ts"]

    if age < 0:
        return {
            "changed": False,
            "msg": "Cannot reasonably calculate time since last backup (host time running ahead), Time since last backup: -%s" % _format_timespan(-age),
            "data": {"state": "WARN", "metrics": {}, "details": ""},
        }

    levels = params.get("levels")
    warn = None
    crit = None
    if levels != None and type(levels) == "list" and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = params.get("warn")
        crit = params.get("crit")

    state = "OK"
    if warn != None and crit != None:
        if age >= crit:
            state = "CRIT"
        elif age >= warn:
            state = "WARN"

    msg = "Last backup: %s, Time since last backup: %s" % (last_ts, _format_timespan(age))
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"backup_age": age},
            "details": "",
        },
    }