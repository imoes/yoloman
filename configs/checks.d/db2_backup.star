def _parse_db2_backup_output(lines):
    """Reproduce parse_db2_dbs for db2_backup section."""
    current_instance = None
    dbs = {}
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[[["):
            current_instance = stripped[3:-3]
            dbs[current_instance] = []
        elif current_instance != None:
            dbs[current_instance].append([stripped])
    return dbs


def _try_parse_timestamp(ts):
    """Parse DB2 timestamp format YYYY-MM-DD-HH.MM.SS without exceptions.
    Returns (year, month, day, hour, minute, second) or None on failure.
    """
    ts = ts[:19]
    parts = ts.split("-")
    if len(parts) != 4:
        return None

    date_part = parts[0]
    month_str = parts[1]
    day_str = parts[2]
    time_str = parts[3]

    tparts = time_str.split(".")
    if len(tparts) != 3:
        return None

    year_str = date_part
    hour_str = tparts[0]
    minute_str = tparts[1]
    second_str = tparts[2]

    for s in [year_str, month_str, day_str, hour_str, minute_str, second_str]:
        if not s.isdigit():
            return None

    return (int(year_str), int(month_str), int(day_str), int(hour_str), int(minute_str), int(second_str))


def _to_epoch(year, month, day, hour, minute, second):
    """Convert calendar time to epoch seconds (local time, like time.mktime)."""
    days = 0
    for y in range(1970, year):
        days += 366 if ((y % 4 == 0 and y % 100 != 0) or y % 400 == 0) else 365

    month_days = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)
    for m in range(1, month):
        days += month_days[m]
        if m == 2 and leap:
            days += 1

    days += (day - 1)
    return days * 86400 + hour * 3600 + minute * 60 + second


def _now_epoch(ctx):
    """Get current time as epoch via the `date` command."""
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc == 0 and res.stdout.strip().isdigit():
        return int(res.stdout.strip())
    return 0


def _gather_db2_backup_raw(ctx):
    """Gather DB2 backup data using db2 list database backup command.
    Returns dict: {instance_name: [[backup_timestamp]]}
    """
    check = ctx.run(["which", "db2"], mutates=False)
    if check.rc != 0:
        return {}

    instances = {}
    res = ctx.run(["db2", "list", "database", "backup"], mutates=False)

    if res.rc == 0:
        in_data = False
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("----"):
                in_data = True
                continue
            if not in_data:
                continue
            if not stripped:
                continue
            fields = stripped.split()
            if len(fields) >= 2:
                db_name = fields[0]
                backup_ts = fields[1]
                if backup_ts == "-" or backup_ts == "0":
                    instances[db_name] = [["-"]]
                else:
                    instances[db_name] = [[backup_ts]]
            elif len(fields) == 1:
                db_name = fields[0]
                instances[db_name] = [["-"]]
    else:
        res2 = ctx.run(["db2", "list", "database"], mutates=False)
        if res2.rc == 0:
            lines = res2.stdout.splitlines()
            db_names = []
            for line in lines:
                stripped = line.strip()
                if stripped.startswith("Database") or stripped.startswith("-"):
                    continue
                if not stripped:
                    continue
                parts = stripped.split()
                if len(parts) >= 1:
                    db_names.append(parts[0])
            for name in db_names:
                instances[name] = [["-"]]

    return instances


def main(ctx, params):
    if params.get("_discover"):
        instances = _gather_db2_backup_raw(ctx)

        discovery = []
        levels = params.get("levels", (86400 * 14, 86400 * 28))
        warn_default = levels[0] if type(levels) == "list" and len(levels) > 0 else 86400 * 14
        crit_default = levels[1] if type(levels) == "list" and len(levels) > 1 else 86400 * 28

        for instance in instances:
            discovery.append({
                "item": instance,
                "params": {"levels": (warn_default, crit_default)},
                "metrics": ["age"],
            })

        return {
            "changed": False,
            "msg": "discovered %d db2 instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- Check mode ---
    item = params.get("item", "")
    instances = _gather_db2_backup_raw(ctx)

    if not item in instances:
        return {
            "changed": False,
            "msg": "no db2 instance found: " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    db = instances.get(item)
    if not db or len(db) == 0 or len(db[0]) == 0:
        return {
            "changed": False,
            "msg": "Login into database failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    timestamp_str = db[0][0]

    if timestamp_str == "-":
        return {
            "changed": False,
            "msg": "No backup available",
            "data": {
                "state": "WARN",
                "metrics": {},
                "details": "",
            },
        }

    parsed = _try_parse_timestamp(timestamp_str[:19])
    if parsed == None:
        return {
            "changed": False,
            "msg": "Last backup contains an invalid timestamp: " + timestamp_str,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    year, month, day, hour, minute, second = parsed
    last_backup = _to_epoch(year, month, day, hour, minute, second)
    now = _now_epoch(ctx)
    age = now - last_backup

    levels = params.get("levels", (86400 * 14, 86400 * 28))
    warn_level = levels[0] if type(levels) == "list" and len(levels) > 0 else 86400 * 14
    crit_level = levels[1] if type(levels) == "list" and len(levels) > 1 else 86400 * 28

    state = "OK"
    if age >= crit_level:
        state = "CRIT"
    elif age >= warn_level:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Time since last backup: age %d seconds" % age,
        "data": {
            "state": state,
            "metrics": {"age": age},
            "details": "",
        },
    }