# timemachine check module for yolo-man agent
# Reads the agent output, calculates backup age, and reports status

def main(ctx, params):
    # Read the timemachine agent output
    section = ""
    if ctx.file_exists("/var/lib/check_mk_agent/spool/timemachine"):
        section = ctx.file_read("/var/lib/check_mk_agent/spool/timemachine").strip()
    else:
        # Try common alternative path for spool file
        res = ctx.run(["cat", "/var/lib/check_mk_agent/spool/timemachine"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "Unable to read timemachine spool file",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": "Spool file not found"}}
        section = res.stdout.strip()
    
    # Discovery mode
    if params.get("_discover"):
        if section != "Unable to locate machine directory for host.":
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {"age": [86400, 172800]}, "metrics": ["backup_age"]}]}
            }
        else:
            return {"changed": False, "msg": "no discovery - backup not configured",
                    "data": {"discovery": []}}
    
    # Check mode for default item (single service)
    item = params.get("item", "")
    if item != "":
        return {"changed": False, "msg": "no items supported for this check",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "This check has only one service"}}
    
    # Check logic
    if not section.startswith("/Volumes/"):
        return {"changed": False, "msg": "Backup seems to have failed",
                "data": {"state": "CRIT", "metrics": {}, "details": "Backup seems to have failed, message was: " + section}}
    
    # Parse backup timestamp
    # Extract timestamp portion: last field after splitting by /
    path_parts = section.split("/")
    backup_time_str = path_parts[len(path_parts) - 1]
    if backup_time_str.endswith(".backup"):
        backup_time_str = backup_time_str[:len(backup_time_str) - 7]
    
    # Split timestamp into components: YYYY-MM-DD-HHMMSS
    timestamp_parts = backup_time_str.split("-")
    if len(timestamp_parts) != 4:
        return {"changed": False, "msg": "Unable to parse backup timestamp",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Backup timestamp format is invalid"}}
    
    # Validate components before parsing
    year_str = timestamp_parts[0]
    month_str = timestamp_parts[1]
    day_str = timestamp_parts[2]
    time_part = timestamp_parts[3]
    if len(time_part) != 6:
        return {"changed": False, "msg": "Unable to parse backup timestamp",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Backup time portion is invalid"}}
    
    # Parse integer components (no try/except, just use.isdigit() guards)
    year = int(year_str) if year_str.isdigit() else 0
    month = int(month_str) if month_str.isdigit() else 0
    day = int(day_str) if day_str.isdigit() else 0
    hour = int(time_part[0:2]) if time_part[0:2].isdigit() else 0
    minute = int(time_part[2:4]) if time_part[2:4].isdigit() else 0
    second = int(time_part[4:6]) if time_part[4:6].isdigit() else 0
    
    # Basic validation
    if year < 1970 or month < 1 or month > 12 or day < 1 or day > 31:
        return {"changed": False, "msg": "Unable to parse backup timestamp",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Backup timestamp values are invalid"}}
    
    # Get current time in seconds since epoch
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Unable to get current time",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Failed to get system time"}}
    current_epoch = int(res.stdout.strip())
    
    # Convert backup time to epoch (simplified: assume UTC for both)
    # Calculate days since 1970 using simplified formula
    days = 0
    for y in range(1970, year):
        is_leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)
        days += 366 if is_leap else 365
    
    # Add days for months in current year
    month_days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)
    days += month_days[month - 1] + day - 1
    if is_leap and month > 2:
        days += 1
    
    backup_epoch = days * 86400 + hour * 3600 + minute * 60 + second
    backup_age = current_epoch - backup_epoch
    
    # Check age thresholds
    warn, crit = params.get("age", [86400, 172800])  # 1d/2d defaults
    
    if backup_age < 0:
        backup_time_formatted = "%d-%d-%d %d:%d:%d" % (year, month, day, hour, minute, second)
        return {"changed": False, "msg": "Backup timestamp in the future",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Timestamp of last backup is in the future: " + backup_time_formatted}}
    
    # Calculate state
    state = "OK"
    summary = ""
    if backup_age >= crit:
        state = "CRIT"
    elif backup_age >= warn:
        state = "WARN"
    
    # Format time span
    if backup_age >= 86400:
        time_ago = "%d d" % int(backup_age / 86400)
    elif backup_age >= 3600:
        time_ago = "%d h" % int(backup_age / 3600)
    elif backup_age >= 60:
        time_ago = "%d m" % int(backup_age / 60)
    else:
        time_ago = "%d s" % int(backup_age)
    
    backup_time_formatted = "%d-%d-%d %d:%d:%d" % (year, month, day, hour, minute, second)
    
    if state == "OK":
        summary = "Backup age: " + time_ago + " ago"
    elif state == "WARN":
        summary = "Backup age: " + time_ago + " ago (warn at 1d)"
    else:
        summary = "Backup age: " + time_ago + " ago (crit at 2d)"
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"backup_age": backup_age}, "details": "Last backup was at " + backup_time_formatted}}
