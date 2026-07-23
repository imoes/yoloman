# ===== Starlark check module for plesk_backups =====
# Read-only: never mutates, never writes.

# Helper to format time (Starlark has no time.strftime)
def _format_timestamp(ts):
    # Approximate %c format: "EEE MMM DD HH:MM:SS YYYY"
    days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    # Compute date from Unix timestamp (UTC only)
    # Use integer division; assume ts >= 0
    secs = ts
    secs_in_day = 86400
    days_since_epoch = secs // secs_in_day
    secs_mod_day = secs % secs_in_day
    hours = secs_mod_day // 3600
    mins = (secs_mod_day % 3600) // 60
    secs_rem = secs_mod_day % 60
    # Compute year, month, day from days_since_epoch (epoch 1970-01-01)
    year = 1970
    while True:
        year_days = 366 if _is_leap_year(year) else 365
        if days_since_epoch < year_days:
            break
        days_since_epoch -= year_days
        year += 1
    month = 0
    while month < 12:
        month_days = _days_in_month(year, month)
        if days_since_epoch < month_days:
            break
        days_since_epoch -= month_days
        month += 1
    day = days_since_epoch + 1
    # Determine weekday (1970-01-01 is Thursday = 4)
    weekday = (4 + ts // secs_in_day) % 7
    return "%s %s %d %d:%d:%d %d" % (days[weekday], months[month], day, hours, mins, secs_rem, year)

def _is_leap_year(y):
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)

def _days_in_month(y, m):
    # m is 0-based
    if m == 1:
        return 29 if _is_leap_year(y) else 28
    elif m == 3 or m == 5 or m == 8 or m == 10:
        return 30
    else:
        return 31

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["plesk", "bin", "backup_manager", "--list"], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            if line.strip() == "":
                continue
            fields = line.split()
            if len(fields) >= 1:
                domain = fields[0]
                items.append({
                    "item": domain,
                    "params": {
                        "backup_age": None,
                        "total_size": None,
                        "no_backup_configured_state": 1,
                        "no_backup_found_state": 1,
                    },
                    "metrics": ["last_backup_size", "last_backup_age", "total_size"],
                })
        return {
            "changed": False,
            "msg": "discovered %d backups" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    res = ctx.run(["plesk", "bin", "backup_manager", "--list"], mutates=False)
    section = {}
    for line in res.stdout.splitlines():
        if line.strip() == "":
            continue
        fields = line.split()
        if len(fields) >= 5:
            section[fields[0]] = fields

    line = section.get(item)
    if line == None:
        return {
            "changed": False,
            "msg": "backup for domain not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if len(line) != 5 or line[1] != "0":
        code = line[1] if len(line) > 1 else "unknown"
        if code == "2":
            return {
                "changed": False,
                "msg": "Error in agent (" + " ".join(line[1:]) + ")",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        elif code == "4":
            state = "WARN" if int(params.get("no_backup_configured_state", 1)) == 1 else "CRIT"
            return {
                "changed": False,
                "msg": "No backup configured",
                "data": {"state": state, "metrics": {}, "details": ""},
            }
        elif code == "5":
            state = "WARN" if int(params.get("no_backup_found_state", 1)) == 1 else "CRIT"
            return {
                "changed": False,
                "msg": "No backup found",
                "data": {"state": state, "metrics": {}, "details": ""},
            }
        else:
            return {
                "changed": False,
                "msg": "Unexpected line " + str(line),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    domain, rc, r_timestamp, r_size, r_total_size = line
    size = int(r_size) if r_size.isdigit() else 0
    total_size = int(r_total_size) if r_total_size.isdigit() else 0
    timestamp = int(r_timestamp) if r_timestamp.isdigit() else 0

    now_res = ctx.run(["date", "+%s"], mutates=False)
    now = int(now_res.stdout.strip())
    age_seconds = now - timestamp

    state = "OK"
    summaries = []

    summaries.append("Size: %d bytes" % size)

    age_levels = params.get("backup_age")
    if age_levels != None and len(age_levels) >= 2:
        warn_age = age_levels[0]
        crit_age = age_levels[1]
        if crit_age != None and age_seconds >= crit_age:
            state = "CRIT"
        elif warn_age != None and age_seconds >= warn_age:
            state = "WARN" if state == "OK" else state
        summaries.append("Age: %d s" % age_seconds)
    else:
        summaries.append("Age: %d s" % age_seconds)

    total_levels = params.get("total_size")
    if total_levels != None and len(total_levels) >= 2:
        warn_total = total_levels[0]
        crit_total = total_levels[1]
        if crit_total != None and total_size >= crit_total:
            state = "CRIT"
        elif warn_total != None and total_size >= warn_total:
            state = "WARN" if state == "OK" else state
        summaries.append("Total: %d bytes" % total_size)
    else:
        summaries.append("Total: %d bytes" % total_size)

    # Format timestamp using our helper
    timestamp_str = _format_timestamp(timestamp)
    summaries.append("Backup time: " + timestamp_str)

    return {
        "changed": False,
        "msg": ", ".join(summaries),
        "data": {
            "state": state,
            "metrics": {
                "last_backup_size": size,
                "last_backup_age": age_seconds,
                "total_size": total_size,
            },
            "details": "",
        },
    }