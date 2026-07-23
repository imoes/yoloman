_MB = 1024.0 * 1024.0
_GB = 1024.0 * 1024.0 * 1024.0
_KB = 1024.0
_STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

_DATAFILES_SQL = "SET NOCOUNT ON;SELECT @@SERVICENAME,DB_NAME(database_id),name,physical_name,CAST(CASE WHEN max_size=-1 THEN -1 ELSE max_size*8.0/1024 END AS DECIMAL(20,2)),CAST(size*8.0/1024 AS DECIMAL(20,2)),CAST(size*8.0/1024 AS DECIMAL(20,2)),CASE WHEN max_size=-1 OR is_percent_growth=1 THEN 1 ELSE 0 END FROM sys.master_files WHERE type=0 ORDER BY database_id,name;"

def _fmt_bytes(b):
    if b >= _GB:
        return "%f GB" % (b / _GB)
    if b >= _MB:
        return "%f MB" % (b / _MB)
    if b >= _KB:
        return "%f KB" % (b / _KB)
    return "%d B" % int(b)

def _parse_num(s):
    s = s.strip()
    if s == "" or s == "NULL":
        return None
    neg = s.startswith("-")
    body = s[1:] if neg else s
    dot_pos = body.find(".")
    if dot_pos >= 0:
        before = body[:dot_pos]
        after = body[dot_pos + 1:]
        if not (before.isdigit() and after.isdigit()):
            return None
    elif not body.isdigit():
        return None
    return float(s)

def _format_item(inst, database, file_name):
    if inst == None or inst == "":
        if file_name == None or file_name == "":
            return database
        return database + "." + file_name
    if file_name == None or file_name == "":
        return inst + "." + database
    return inst + "." + database + "." + file_name

def _worst(a, b):
    if _STATE_ORDER.get(a, 0) >= _STATE_ORDER.get(b, 0):
        return a
    return b

def _check_pct(value, ref, levels):
    if levels == None or levels[0] == None:
        return "OK"
    if ref == None or ref <= 0.0:
        return "OK"
    warn = float(levels[0]) * ref / 100.0
    crit = float(levels[1]) * ref / 100.0
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _run_sqlcmd(ctx, params):
    host = params.get("host", "localhost")
    instance = params.get("instance", "")
    user = params.get("user", "")
    password = params.get("password", "")
    port = str(params.get("port", 1433))
    if instance != "":
        server = host + "\\" + instance
    else:
        server = host + "," + port
    if user != "" and password != "":
        argv = ["sqlcmd", "-S", server, "-U", user, "-P", password,
                "-h", "-1", "-s", "|", "-W", "-Q", _DATAFILES_SQL]
    else:
        argv = ["sqlcmd", "-S", server, "-E",
                "-h", "-1", "-s", "|", "-W", "-Q", _DATAFILES_SQL]
    return ctx.run(argv, mutates=False)

def _parse_rows(stdout):
    rows = []
    for line in stdout.splitlines():
        line = line.strip()
        if line == "" or line.startswith("---") or line.startswith("("):
            continue
        parts = line.split("|")
        if len(parts) < 8:
            continue
        inst = parts[0].strip()
        database = parts[1].strip()
        if database == "" or database == "NULL":
            continue
        file_name = parts[2].strip()
        max_raw = _parse_num(parts[4])
        alloc_raw = _parse_num(parts[5])
        used_raw = _parse_num(parts[6])
        unlimited = (parts[7].strip() == "1") or (max_raw != None and max_raw < 0.0)
        max_bytes = None if (max_raw == None or max_raw < 0.0) else (max_raw * _MB)
        alloc_bytes = alloc_raw * _MB if alloc_raw != None else None
        used_bytes = used_raw * _MB if used_raw != None else None
        rows.append({
            "key": _format_item(inst, database, file_name),
            "summary_key": _format_item(inst, database, None),
            "max_bytes": max_bytes,
            "alloc_bytes": alloc_bytes,
            "used_bytes": used_bytes,
            "unlimited": unlimited,
        })
    return rows

def main(ctx, params):
    res = _run_sqlcmd(ctx, params)
    if res.rc != 0:
        err = res.stderr.strip()
        if err == "":
            err = res.stdout.strip()
        return {
            "changed": False,
            "msg": "sqlcmd failed: " + err,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": err},
        }

    rows = _parse_rows(res.stdout)

    if params.get("_discover"):
        discovery = [
            {
                "item": r["key"],
                "params": {"used_levels": (80.0, 90.0)},
                "metrics": ["data_size", "allocated_size"],
            }
            for r in rows
        ]
        return {
            "changed": False,
            "msg": "discovered %d datafiles" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    matching = [r for r in rows if r["key"] == item or r["summary_key"] == item]

    if len(matching) == 0:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used_sum = 0.0
    alloc_sum = 0.0
    max_sum = 0.0
    for m in matching:
        u = m["used_bytes"] if m["used_bytes"] != None else 0.0
        a = m["alloc_bytes"] if m["alloc_bytes"] != None else 0.0
        used_sum += u
        alloc_sum += a
        if m["max_bytes"] == None or m["unlimited"] or m["max_bytes"] <= 0.0:
            max_sum += a
        else:
            max_sum += m["max_bytes"]

    if max_sum <= 0.0:
        max_sum = alloc_sum

    used_levels = params.get("used_levels", (80.0, 90.0))
    alloc_used_levels = params.get("allocated_used_levels", (None, None))
    alloc_levels = params.get("allocated_levels", (None, None))

    state = _worst(
        _check_pct(used_sum, max_sum, used_levels),
        _worst(
            _check_pct(used_sum, alloc_sum, alloc_used_levels),
            _check_pct(alloc_sum, max_sum, alloc_levels),
        ),
    )

    msg = "Used: %s, Allocated: %s, Maximum size: %s" % (
        _fmt_bytes(used_sum),
        _fmt_bytes(alloc_sum),
        _fmt_bytes(max_sum),
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"data_size": used_sum, "allocated_size": alloc_sum},
            "details": "",
        },
    }