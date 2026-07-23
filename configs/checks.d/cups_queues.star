def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lpr", "-p"], mutates=False)
        queues = []
        lines = res.stdout.splitlines()
        i = 0
        while i < len(lines):
            line = lines[i]
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "printer":
                queue_name = parts[1]
                queues.append({
                    "item": queue_name,
                    "params": {
                        "job_count": [5, 10],
                        "job_age": [360, 720],
                        "is_idle": 0,
                        "now_printing": 0,
                        "disabled_since": 2
                    },
                    "metrics": ["jobs_count", "oldest_job_age"]
                })
            i += 1
        return {
            "changed": False,
            "msg": "discovered %d queues" % len(queues),
            "data": {"discovery": queues}
        }
    
    item = params.get("item", "")
    res = ctx.run(["lpr", "-p"], mutates=False)
    lines = res.stdout.splitlines()
    
    # Parse section: extract queue statuses
    section = {}
    i = 0
    while i < len(lines):
        line = lines[i]
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "printer":
            queue_name = parts[1]
            status_parts = parts[2:4]
            status_readable = " ".join(status_parts).replace(" ", "_").strip(".")
            
            # Gather full output and potential continuation line
            output = " ".join(parts[2:])
            if i + 1 < len(lines) and lines[i+1].split()[0] not in ["printer", "---"]:
                output += " (%s)" % lines[i+1].strip()
            
            section[queue_name] = {
                "status_readable": status_readable,
                "output": output,
                "jobs": []
            }
            i += 2 if (i + 1 < len(lines) and lines[i+1].split()[0] not in ["printer", "---"]) else 1
            continue
        
        if parts[0] == "---":
            i += 1
            continue
        
        # Job line: parse time from end
        if len(parts) >= 5:
            queue_name = parts[0].split("-", 1)[0]
            if queue_name in section:
                # Try format: Tue Jun 29 09:05:54 2010 (5 parts at end)
                job_time_str = " ".join(parts[-5:])
                job_time = parse_cups_time(job_time_str)
                if job_time != None:
                    section[queue_name]["jobs"].append(job_time)
        i += 1
    
    # Check logic
    if item not in section:
        return {
            "changed": False,
            "msg": "Queue not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    data = section[item]
    status = data["status_readable"]
    params_map = params.get("params", {})
    
    # Determine state based on status readable string
    state = "UNKNOWN"
    status_key = status.replace(" ", "_").lower().strip(".")
    
    state_key = None
    if "is_idle" in status.lower():
        state_key = "is_idle"
    elif "now_printing" in status.lower():
        state_key = "now_printing"
    elif "disabled_since" in status.lower():
        state_key = "disabled_since"
    
    if state_key != None and state_key in params_map:
        state_val = params_map[state_key]
        if state_val == 0:
            state = "OK"
        elif state_val == 1:
            state = "WARN"
        elif state_val == 2:
            state = "CRIT"
        elif state_val == 3:
            state = "UNKNOWN"
        else:
            state = "UNKNOWN"
    else:
        state = "UNKNOWN"
    
    # Job counts and age
    jobs_count = len(data["jobs"])
    jobs_warn = None
    jobs_crit = None
    if "job_count" in params_map:
        jc = params_map["job_count"]
        if type(jc) == "list" and len(jc) == 2:
            jobs_warn = jc[0]
            jobs_crit = jc[1]
    
    msg_parts = [data["output"]]
    
    # Job count levels
    if jobs_count > 0:
        if jobs_warn != None and jobs_crit != None:
            if jobs_count >= jobs_crit:
                state = "CRIT"
            elif jobs_count >= jobs_warn:
                if state != "CRIT":
                    state = "WARN"
        msg_parts.append("%d jobs" % jobs_count)
    else:
        msg_parts.append("0 jobs")
    
    # Oldest job time
    oldest = None
    if jobs_count > 0:
        oldest = min(data["jobs"])
        msg_parts.append("oldest %s ago" % format_timespan(get_current_timestamp(ctx) - oldest))
    
    # Job age levels
    if oldest != None:
        job_age = get_current_timestamp(ctx) - oldest
        age_warn = None
        age_crit = None
        if "job_age" in params_map:
            ja = params_map["job_age"]
            if type(ja) == "list" and len(ja) == 2:
                age_warn = ja[0]
                age_crit = ja[1]
        
        if age_warn != None and age_crit != None:
            if job_age >= age_crit:
                state = "CRIT"
            elif job_age >= age_warn:
                if state != "CRIT":
                    state = "WARN"
    
    return {
        "changed": False,
        "msg": "; ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {
                "jobs_count": jobs_count,
                "oldest_job_age": get_current_timestamp(ctx) - (oldest if oldest else get_current_timestamp(ctx))
            },
            "details": ""
        }
    }


def get_current_timestamp(ctx):
    # Approximate epoch timestamp by relying on system's date command
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc == 0 and res.stdout.strip().isdigit():
        return int(res.stdout.strip())
    return 0


def parse_cups_time(time_str):
    # Format: "Tue Jun 29 09:05:54 2010"
    # Only support first format as primary; handle gracefully without try/except
    if len(time_str.split()) != 5:
        return None
    
    parts = time_str.split()
    # Month map
    months = {
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12
    }
    month = months.get(parts[1])
    if month == None:
        return None
    
    # Validate components
    day_str = parts[2]
    year_str = parts[4]
    time_part = parts[3].split(":")
    if len(time_part) != 3:
        return None
    
    # Guard-based parsing — no try/except
    day = int(day_str) if day_str.isdigit() else 0
    year = int(year_str) if year_str.isdigit() else 0
    hour = int(time_part[0]) if time_part[0].isdigit() else 0
    minute = int(time_part[1]) if time_part[1].isdigit() else 0
    second = int(time_part[2]) if time_part[2].isdigit() else 0
    
    # Bounds checking
    if month < 1 or month > 12 or day < 1 or day > 31 or year < 1970 or year > 2100:
        return None
    if hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59:
        return None
    
    # Compute seconds since epoch (approximation)
    days_in_month = [31,28,31,30,31,30,31,31,30,31,30,31]
    def is_leap(y):
        return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)
    
    # Days from year 1970 to given year
    total_days = 0
    for y in range(1970, year):
        total_days += 366 if is_leap(y) else 365
    
    # Days from months in year
    for m in range(1, month):
        total_days += days_in_month[m-1]
    if month > 2 and is_leap(year):
        total_days += 1
    
    total_days += day - 1
    total_seconds = total_days * 86400 + hour * 3600 + minute * 60 + second
    return total_seconds


def format_timespan(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    elif seconds < 3600:
        return "%dm %ds" % (seconds // 60, seconds % 60)
    elif seconds < 86400:
        return "%dh %dm" % (seconds // 3600, (seconds % 3600) // 60)
    else:
        return "%dd %dh" % (seconds // 86400, (seconds % 86400) // 3600)