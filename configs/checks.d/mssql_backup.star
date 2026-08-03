# ===== Starlark translation of checkmk mssql_backup =====

_MAP_BACKUP_TYPES = {
    "D": "database",
    "I": "database diff",
    "L": "log",
    "F": "file or filegroup",
    "G": "file diff",
    "P": "partial",
    "Q": "partial diff",
    "-": "unspecific",
}


def _find_sqlcmd(ctx):
    """Locate sqlcmd binary. Returns None if not found."""
    for path in ["/usr/bin/sqlcmd", "/opt/mssql-tools/bin/sqlcmd", "/usr/local/bin/sqlcmd"]:
        if ctx.file_exists(path):
            return path
    res = ctx.run(["which", "sqlcmd"], mutates=False)
    if res.rc == 0:
        p = res.stdout.strip()
        if p != "":
            return p
    return None


def _parse_sqlcmd_output(output):
    """Parse sqlcmd -s output (pipe-separated). Returns list of row lists."""
    rows = []
    lines = output.splitlines()
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        if stripped.startswith("-") and stripped.endswith("-"):
            continue
        if stripped.lower().startswith("timestamp"):
            continue
        parts = stripped.split("|")
        if len(parts) < 3:
            parts = stripped.split()
        if len(parts) >= 3:
            rows.append(parts)
    return rows


def _parse_date_to_timestamp(date_str, time_str):
    """Parse date/time string to epoch timestamp. Returns None on failure."""
    if time_str == "" or time_str == None:
        cleaned = date_str.strip()
        if cleaned.lstrip("-").isdigit():
            return float(int(cleaned))
        return None

    dt_str = date_str + " " + time_str
    if "+" in dt_str:
        dt_str = dt_str.split("+")[0]

    parts = dt_str.split(" ")
    if len(parts) < 2:
        return None

    date_part = parts[0]
    time_part = parts[1]

    dp = date_part.split("-")
    tp = time_part.split(":")
    if len(dp) != 3 or len(tp) < 2:
        return None

    year_str = dp[0]
    month_str = dp[1]
    day_str = dp[2]
    hour_str = tp[0]
    minute_str = tp[1]
    second_str = tp[2] if len(tp) > 2 else "0"

    if not year_str.isdigit() or not month_str.isdigit() or not day_str.isdigit():
        return None
    if not hour_str.isdigit() or not minute_str.isdigit() or not second_str.isdigit():
        return None

    year = int(year_str)
    month = int(month_str)
    day = int(day_str)
    hour = int(hour_str)
    minute = int(minute_str)
    second = int(second_str)

    days_in_month = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if month <= 2:
        year_adj = year - 1
    else:
        year_adj = year

    leap = 0
    if (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0):
        leap = 1

    days = year_adj * 365 + year_adj // 4 - year_adj // 100 + year_adj // 400
    for m in range(month - 1):
        days += days_in_month[m]
    days += day
    if leap and month > 2:
        days += 1

    return float(days * 86400 + hour * 3600 + minute * 60 + second)


def _query_backupset(ctx, sqlcmd_path, host, instance, user, password, db_name):
    """Query backupset for a specific database. Returns raw rows or None."""
    if instance != "":
        conn_str = host + "\\" + instance
    else:
        conn_str = host

    args = [sqlcmd_path, "-S", conn_str]

    if user != None and password != None:
        args = args + ["-U", user, "-P", password]
    else:
        args = args + ["-E"]

    query = "SET NOCOUNT ON; SELECT TOP 100 CONVERT(varchar, bs.backup_finish_date, 120) AS ts, CASE bs.type WHEN 'D' THEN 'D' WHEN 'I' THEN 'I' WHEN 'L' THEN 'L' WHEN 'F' THEN 'F' WHEN 'G' THEN 'G' WHEN 'P' THEN 'P' WHEN 'Q' THEN 'Q' ELSE '-' END AS bt, CASE WHEN bs.name IS NULL THEN 'no backup found' ELSE '' END AS st FROM msdb.dbo.backupset bs WHERE bs.database_name = '" + db_name + "' ORDER BY bs.backup_finish_date DESC;"

    args = args + ["-d", "msdb", "-s", "|", "-W", "-Q", query]

    res = ctx.run(args, mutates=False, ok_codes=[0, 1, 2, 100])
    if res.rc != 0:
        return None
    return _parse_sqlcmd_output(res.stdout)


def _get_current_time(ctx):
    """Get current time via date command. Returns epoch seconds or None."""
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc != 0:
        return None
    ts_str = res.stdout.strip()
    if ts_str.lstrip("-").isdigit():
        return float(int(ts_str))
    return None


def _format_timespan(seconds):
    """Format seconds into a human-readable timespan."""
    seconds = int(seconds)
    if seconds < 0:
        return "unknown"
    if seconds < 60:
        return "%d s" % seconds
    if seconds < 3600:
        return "%d m %d s" % (seconds // 60, seconds % 60)
    if seconds < 86400:
        return "%d h %d m" % (seconds // 3600, (seconds % 3600) // 60)
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    return "%d days %d h" % (days, hours)


def _format_datetime(ctx, timestamp):
    """Format timestamp into readable date/time."""
    if timestamp == None:
        return "unknown"
    ts = int(timestamp)
    res = ctx.run(["date", "-d", "@" + str(ts), "+%Y-%m-%d %H:%M:%S"], mutates=False)
    if res.rc == 0:
        return res.stdout.strip()
    return str(ts)


def _discover_instances(ctx, sqlcmd_path):
    """Discover SQL Server instances. Returns list of (host, instance) tuples."""
    res = ctx.run(["sqlcmd", "-Lc"], mutates=False)
    if res.rc != 0:
        return []
    instances = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "" or line.startswith("Server:"):
            continue
        hparts = line.split("\\")
        if len(hparts) == 1:
            instances.append((hparts[0], ""))
        else:
            instances.append((hparts[0], hparts[1]))
    return instances


def _discover_databases(ctx, sqlcmd_path, host, instance, user, password):
    """Discover databases on an SQL Server instance."""
    if instance != "":
        conn_str = host + "\\" + instance
    else:
        conn_str = host

    args = [sqlcmd_path, "-S", conn_str]

    if user != None and password != None:
        args = args + ["-U", user, "-P", password]
    else:
        args = args + ["-E"]

    args = args + ["-s", "|", "-Q", "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name;"]

    res = ctx.run(args, mutates=False, ok_codes=[0, 1, 2, 100])
    if res.rc != 0:
        return []

    dbs = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "" or line.lower() == "name" or line.startswith("-"):
            continue
        if line.startswith("name|"):
            continue
        dbs.append(line)
    return dbs


def main(ctx, params):
    if params.get("_discover"):
        sqlcmd_path = _find_sqlcmd(ctx)
        if sqlcmd_path == None:
            return {"changed": False, "msg": "no sqlcmd found, no discovery",
                    "data": {"discovery": []}}

        instances = _discover_instances(ctx, sqlcmd_path)
        if len(instances) == 0:
            instances = [("localhost", "")]

        user = params.get("user")
        password = params.get("password")

        discovery = []
        metric_names = ["seconds"]

        for host, instance in instances:
            dbs = _discover_databases(ctx, sqlcmd_path, host, instance, user, password)
            if len(dbs) == 0:
                continue
            for db_name in dbs:
                item = host + " " + db_name
                discovery.append({"item": item, "params": {}, "metrics": metric_names})

        return {"changed": False,
                "msg": "discovered %d mssql backup items" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    sqlcmd_path = _find_sqlcmd(ctx)
    if sqlcmd_path == None:
        return {"changed": False,
                "msg": "Failed to connect to database: sqlcmd not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")
    item_parts = item.split(" ", 1)
    if len(item_parts) != 2:
        return {"changed": False,
                "msg": "Invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    host = item_parts[0]
    db_name = item_parts[1]
    instance = ""

    if "\\" in host:
        hparts = host.split("\\", 1)
        host = hparts[0]
        instance = hparts[1]

    user = params.get("user")
    password = params.get("password")

    rows = _query_backupset(ctx, sqlcmd_path, host, instance, user, password, db_name)
    if rows == None or len(rows) == 0:
        return {"changed": False,
                "msg": "Failed to connect to database",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Failed to query backupset for " + db_name}}

    backups = []
    for row in rows:
        if len(row) < 3:
            continue
        timestamp_str = row[0]
        backup_type_code = row[1]
        state_str = row[2]

        b_time = None
        b_date = timestamp_str

        if " " in timestamp_str:
            dp = timestamp_str.split(" ")
            b_date = dp[0]
            b_time = dp[1]

        timestamp = _parse_date_to_timestamp(b_date, b_time)
        backup_type = _MAP_BACKUP_TYPES.get(backup_type_code, None)
        backups.append({"timestamp": timestamp, "type": backup_type, "state": state_str or ""})

    now = _get_current_time(ctx)

    if len(backups) == 0:
        return {"changed": False,
                "msg": "No backup found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "No backups found for " + db_name}}

    backup = backups[0]

    if backup["state"] == "no backup found":
        not_found = params.get("not_found", 1)
        state = "WARN" if not_found == 1 else ("CRIT" if not_found == 2 else "OK")
        return {"changed": False,
                "msg": "No backup found",
                "data": {"state": state, "metrics": {}, "details": ""}}

    if backup["state"].startswith("ERROR: "):
        return {"changed": False,
                "msg": backup["state"][7:],
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    btype = backup["type"]
    if btype == None:
        backup_type_var = "database"
        perfkey = "seconds"
        backup_type_info = "[database]"
    else:
        clean_type = btype.strip().replace(" ", "_")
        backup_type_var = clean_type
        perfkey = "backup_age_%s" % clean_type
        backup_type_info = "[%s]" % btype

    summary = "%s Last backup: %s" % (backup_type_info, _format_datetime(ctx, backup["timestamp"]))

    if backup["timestamp"] == None:
        return {"changed": False,
                "msg": summary,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    if now != None:
        age = now - backup["timestamp"]
    else:
        age = 0

    if age < 0:
        return {"changed": False,
                "msg": "Cannot reasonably calculate time since last backup (hosts time is running ahead), Time since last backup: -" + _format_timespan(age),
                "data": {"state": "WARN", "metrics": {}, "details": ""}}

    levels = params.get(backup_type_var)
    if levels == None:
        return {"changed": False,
                "msg": summary + ", Time since last backup: " + _format_timespan(age),
                "data": {"state": "OK", "metrics": {perfkey: age}, "details": ""}}

    warn_val = None
    crit_val = None
    if type(levels) == "list" and len(levels) >= 2:
        warn_val = levels[0]
        crit_val = levels[1]

    if crit_val != None and age >= crit_val:
        state = "CRIT"
    elif warn_val != None and age >= warn_val:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": summary + ", Time since last backup: " + _format_timespan(age),
            "data": {"state": state, "metrics": {perfkey: age}, "details": ""}}