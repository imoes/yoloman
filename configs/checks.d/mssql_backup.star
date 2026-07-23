def _parse_date_and_time(b_date, b_time):
    if b_time == None:
        return int(b_date) if b_date.lstrip("-").isdigit() else None
    if "+" in b_time:
        parts = b_time.rsplit("+", 1)
        if len(parts) == 2:
            b_time = parts[0]
    dt_str = b_date + " " + b_time
    parts = dt_str.split(" ")
    if len(parts) != 2:
        return None
    date_part = parts[0]
    time_part = parts[1]
    date_parts = date_part.split("-")
    if len(date_parts) != 3:
        return None
    year = int(date_parts[0]) if date_parts[0].lstrip("-").isdigit() else 0
    month = int(date_parts[1]) if date_parts[1].lstrip("-").isdigit() else 0
    day = int(date_parts[2]) if date_parts[2].lstrip("-").isdigit() else 0
    time_parts = time_part.split(":")
    if len(time_parts) != 3:
        return None
    hour = int(time_parts[0]) if time_parts[0].lstrip("-").isdigit() else 0
    minute = int(time_parts[1]) if time_parts[1].lstrip("-").isdigit() else 0
    second = int(time_parts[2]) if time_parts[2].lstrip("-").isdigit() else 0
    y = year - 1
    leap_days = y // 4 - y // 100 + y // 400
    days_since_epoch = (year - 1970) * 365 + leap_days
    month_days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    if month > 1:
        days_since_epoch += month_days[month - 1]
    days_since_epoch += day - 1
    is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)
    if is_leap and month > 2:
        days_since_epoch += 1
    seconds = days_since_epoch * 86400 + hour * 3600 + minute * 60 + second
    return float(seconds)

def _map_backup_type(b_type):
    if b_type == None:
        return None
    mapping = {
        "D": "database",
        "I": "database diff",
        "L": "log",
        "F": "file or filegroup",
        "G": "file diff",
        "P": "partial",
        "Q": "partial diff",
        "-": "unspecific"
    }
    return mapping.get(b_type)

def main(ctx, params):
    if params.get("_discover"):
        path = "/var/lib/mssql_backup.info"
        if not ctx.file_exists(path):
            return {"changed": False, "msg": "discovered 0 items (no data file)",
                    "data": {"discovery": []}}
        content = ctx.file_read(path)
        lines = content.splitlines()
        data = {}
        for line in lines:
            if line.strip() == "":
                continue
            if "|" in line:
                fields = line.split("|")
            else:
                fields = line.split(None, 5)
            if len(fields) < 3:
                continue
            inst = fields[0]
            tablespace = fields[1]
            b_date = fields[2]
            b_time = None
            b_type = None
            if len(fields) >= 4 and fields[3] != "":
                b_time = fields[3]
            if len(fields) >= 5 and fields[4] != "":
                b_type = fields[4]
            timestamp = _parse_date_and_time(b_date, b_time)
            backup_type = _map_backup_type(b_type)
            item = inst + " " + tablespace
            if item not in data:
                data[item] = []
            data[item].append({"timestamp": timestamp, "type": backup_type, "state": ""})
        discovery = []
        for item in data:
            discovery.append({"item": item, "params": {}, "metrics": ["backup_age"]})
        return {"changed": False, "msg": "discovered %d databases" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if item == None:
        item = ""
    path = "/var/lib/mssql_backup.info"
    if not ctx.file_exists(path):
        return {"changed": False, "msg": "no data file",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    content = ctx.file_read(path)
    lines = content.splitlines()
    data = {}
    for line in lines:
        if line.strip() == "":
            continue
        if "|" in line:
            fields = line.split("|")
        else:
            fields = line.split(None, 5)
        if len(fields) < 3:
            continue
        inst = fields[0]
        tablespace = fields[1]
        b_date = fields[2]
        b_time = None
        b_type = None
        if len(fields) >= 4 and fields[3] != "":
            b_time = fields[3]
        if len(fields) >= 5 and fields[4] != "":
            b_type = fields[4]
        timestamp = _parse_date_and_time(b_date, b_time)
        backup_type = _map_backup_type(b_type)
        db_item = inst + " " + tablespace
        if db_item not in data:
            data[db_item] = []
        data[db_item].append({"timestamp": timestamp, "type": backup_type, "state": ""})

    backups = data.get(item)
    if backups == None or len(backups) == 0:
        return {"changed": False, "msg": "backup data not found for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    latest = None
    latest_backup = None
    for backup in backups:
        ts = backup.get("timestamp")
        if ts == None:
            continue
        if latest == None or ts > latest:
            latest = ts
            latest_backup = backup

    if latest_backup == None:
        return {"changed": False, "msg": "no valid backup record",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    now = float(ctx.run(["date", "+%s"], mutates=False).stdout.strip())
    if latest == None:
        age = None
    else:
        age = now - latest

    backup_type = latest_backup.get("type")
    if backup_type == None:
        backup_type_var = "database"
        perfkey = "backup_age"
        backup_type_info = "[database]"
    else:
        backup_type_var = backup_type.strip().replace(" ", "_")
        perfkey = "backup_age_" + backup_type_var
        backup_type_info = "[" + backup_type + "]"

    state = "OK"
    msg = backup_type_info + " Last backup: " + str(int(latest))
    age_for_levels = age

    levels = params.get("levels")
    if levels == None:
        levels = params.get(backup_type_var)
    if levels == None:
        levels = ["no_levels", None]
    if type(levels) == "list" and len(levels) >= 2:
        level_type = levels[0]
        level_value = levels[1]
        if level_type == "fixed" and age_for_levels != None:
            if age_for_levels >= level_value:
                state = "CRIT"
            elif age_for_levels >= level_value * 0.8:
                state = "WARN"

    metrics = {}
    if age_for_levels != None:
        metrics["backup_age"] = int(age_for_levels)

    return {"changed": False, "msg": backup_type_info + " Last backup: " + str(int(latest)),
            "data": {"state": state, "metrics": metrics, "details": ""}}