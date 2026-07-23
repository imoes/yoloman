WARN_DEFAULT = 1209600  # 14 days in seconds
CRIT_DEFAULT = 2419200  # 28 days in seconds

DAYS_IN_MONTH = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

def _is_leap(y):
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)

def _days_since_epoch(year, month, day):
    total = 0
    for y in range(1970, year):
        total += 366 if _is_leap(y) else 365
    for m in range(1, month):
        d = DAYS_IN_MONTH[m]
        if m == 2 and _is_leap(year):
            d += 1
        total += d
    total += day - 1
    return total

def _parse_ts(ts):
    # DB2 format: "2015-03-12-04.00.13.000000" -> epoch seconds (UTC approximation)
    s = ts.strip()
    if len(s) < 19:
        return None
    parts = s[:19].split("-")
    if len(parts) < 4:
        return None
    if not parts[0].isdigit() or not parts[1].isdigit() or not parts[2].isdigit():
        return None
    year = int(parts[0])
    month = int(parts[1])
    day = int(parts[2])
    tp = parts[3].split(".")
    if len(tp) < 3:
        return None
    if not tp[0].isdigit() or not tp[1].isdigit() or not tp[2].isdigit():
        return None
    epoch = _days_since_epoch(year, month, day) * 86400
    epoch += int(tp[0]) * 3600 + int(tp[1]) * 60 + int(tp[2])
    return epoch

def _fmt_age(secs):
    if secs < 0:
        secs = -secs
    days = secs // 86400
    hours = (secs % 86400) // 3600
    mins = (secs % 3600) // 60
    if days > 0:
        return "%d days %d hours" % (days, hours)
    if hours > 0:
        return "%d hours %d minutes" % (hours, mins)
    if mins > 0:
        return "%d minutes" % mins
    return "%d seconds" % (secs % 60)

def _get_now(ctx):
    r = ctx.run(["date", "+%s"], mutates=False)
    s = r.stdout.strip()
    return int(s) if s.isdigit() else 0

def _list_instances(ctx):
    r = ctx.run(["db2ilist"], mutates=False, ok_codes=[0, 1, 2, 127])
    if r.rc != 0 or not r.stdout.strip():
        return []
    return [l.strip() for l in r.stdout.splitlines() if l.strip()]

def _list_databases(ctx, instance):
    cmd = "db2 list db directory 2>/dev/null | awk '/Database alias/{print $NF}'"
    r = ctx.run(["su", "-", instance, "-c", cmd], mutates=False, ok_codes=[0, 1, 2])
    if not r.stdout.strip():
        return []
    return [l.strip() for l in r.stdout.splitlines() if l.strip()]

def _query_backup(ctx, instance, db):
    sql = "SELECT VARCHAR(entry_time,26) FROM sysibmadm.db_history WHERE operation='B' ORDER BY entry_time DESC FETCH FIRST 1 ROW ONLY"
    cmd = "db2 connect to " + db + " >/dev/null 2>&1 && db2 -x \"" + sql + "\" 2>/dev/null || echo __FAILED__"
    r = ctx.run(["su", "-", instance, "-c", cmd], mutates=False, ok_codes=[0, 1, 2])
    out = r.stdout.strip()
    if "__FAILED__" in out:
        return None
    for line in out.splitlines():
        line = line.strip()
        if line:
            return line
    return "-"

def main(ctx, params):
    if params.get("_discover"):
        instances = _list_instances(ctx)
        items = []
        for instance in instances:
            dbs = _list_databases(ctx, instance)
            for db in dbs:
                items.append({
                    "item": instance + ":" + db,
                    "params": {"warn": WARN_DEFAULT, "crit": CRIT_DEFAULT},
                    "metrics": ["age"],
                })
        return {
            "changed": False,
            "msg": "discovered %d DB2 instance/database pairs" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    colon = item.find(":")
    if colon < 0:
        return {
            "changed": False,
            "msg": "invalid item format, expected instance:database",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    instance = item[:colon]
    db = item[colon + 1:]

    raw = _query_backup(ctx, instance, db)

    if raw == None:
        return {
            "changed": False,
            "msg": "Login into database failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not raw or raw == "-":
        return {
            "changed": False,
            "msg": "No backup available",
            "data": {"state": "WARN", "metrics": {}, "details": ""},
        }

    epoch = _parse_ts(raw)
    if epoch == None:
        return {
            "changed": False,
            "msg": "Last backup contains an invalid timestamp: " + raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    now = _get_now(ctx)
    if now == 0:
        return {
            "changed": False,
            "msg": "Failed to determine current time",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    age = now - epoch

    levels = params.get("levels", None)
    if levels != None:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = params.get("warn", WARN_DEFAULT)
        crit = params.get("crit", CRIT_DEFAULT)

    state = "CRIT" if age >= crit else ("WARN" if age >= warn else "OK")

    return {
        "changed": False,
        "msg": "Time since last backup: " + _fmt_age(age),
        "data": {
            "state": state,
            "metrics": {"age": age},
            "details": "Last backup: " + raw,
        },
    }