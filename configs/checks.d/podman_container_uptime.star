def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Probe container inspect data
        res_inspect = ctx.run(["podman", "inspect", "--format=json", "podman_container"], mutates=False)
        if res_inspect.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Guard before JSON decode - check if stdout is non-empty
        if res_inspect.stdout == "":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Only decode if stdout is non-empty (no try/except allowed)
        containers = json.decode(res_inspect.stdout)
        
        # Check if agent uptime service exists (to suppress duplicate service)
        res_uptime = ctx.run(["cat", "/proc/uptime"], mutates=False)
        if res_uptime.rc == 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Find running or exited containers
        discovered = []
        for container in containers:
            if type(container) == "dict":
                state = container.get("State", {})
                if type(state) == "dict":
                    status = state.get("Status", "")
                    if status in ("running", "exited"):
                        discovered.append({
                            "item": "",
                            "params": {},
                            "metrics": ["uptime"]
                        })
                        break  # Single-service check; only one item
        
        return {"changed": False, "msg": "discovered %d items" % len(discovered),
                "data": {"discovery": discovered}}
    
    # Check mode
    # Probe container inspect data
    res_inspect = ctx.run(["podman", "inspect", "--format=json", "podman_container"], mutates=False)
    if res_inspect.rc != 0:
        return {"changed": False, "msg": "no container found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Guard before JSON decode
    if res_inspect.stdout == "":
        return {"changed": False, "msg": "no container found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    containers = json.decode(res_inspect.stdout)
    
    if type(containers) != "list" or len(containers) == 0:
        return {"changed": False, "msg": "no container found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    container = containers[0]
    if type(container) != "dict":
        return {"changed": False, "msg": "no container found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state = container.get("State", {})
    if type(state) != "dict":
        return {"changed": False, "msg": "no state data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    status = state.get("Status", "")
    if status == "running":
        # Get started_at timestamp
        started_at = state.get("StartedAt", "")
        if started_at == "":
            return {"changed": False, "msg": "started_at timestamp missing",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        # Calculate uptime in seconds
        now_res = ctx.run(["date", "+%s"], mutates=False)
        if now_res.rc != 0:
            return {"changed": False, "msg": "could not get current time",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        now_epoch_str = now_res.stdout.strip()
        if not now_epoch_str.isdigit():
            return {"changed": False, "msg": "could not parse current time",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        now_epoch = int(now_epoch_str)
        
        # Parse ISO 8601 timestamp to epoch
        ts = started_at.strip()
        # Remove trailing Z if present
        if ts.endswith("Z"):
            ts = ts[:-1]
        # Split date and time
        parts = ts.split("T")
        if len(parts) != 2:
            return {"changed": False, "msg": "could not parse started_at timestamp",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        date_part, time_part = parts[0], parts[1]
        
        # Extract year, month, day
        ymd = date_part.split("-")
        if len(ymd) != 3:
            return {"changed": False, "msg": "could not parse date part",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        year = int(ymd[0])
        month = int(ymd[1])
        day = int(ymd[2])
        
        # Extract time components
        hms = time_part.split(":")
        if len(hms) < 2:
            return {"changed": False, "msg": "could not parse time part",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        hour = int(hms[0])
        minute = int(hms[1])
        
        # Extract seconds (may have decimal)
        sec_parts = hms[2].split(".")
        if len(sec_parts) == 0:
            return {"changed": False, "msg": "could not parse seconds part",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        second = int(sec_parts[0])
        
        # Calculate days from 1970-01-01 to target date
        def days_in_month(m, y):
            if m in [1, 3, 5, 7, 8, 10, 12]:
                return 31
            elif m == 2:
                if (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0):
                    return 29
                else:
                    return 28
            else:
                return 30
        
        total_days = 0
        for y in range(1970, year):
            if (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0):
                total_days += 366
            else:
                total_days += 365
        for m in range(1, month):
            total_days += days_in_month(m, year)
        total_days += day - 1
        
        started_epoch = total_days * 86400 + hour * 3600 + minute * 60 + second
        uptime_sec = now_epoch - started_epoch
        
        if uptime_sec < 0:
            uptime_sec = 0
        
        # Build message string (Checkmk style)
        uptime_sec = int(uptime_sec)
        days = uptime_sec // 86400
        hours = (uptime_sec % 86400) // 3600
        minutes = (uptime_sec % 3600) // 60
        
        msg_parts = []
        if days > 0:
            msg_parts.append("%d d" % days)
        if hours > 0 or days > 0:
            msg_parts.append("%d h" % hours)
        msg_parts.append("%d min" % minutes)
        
        msg = "Operational state: running, " + ", ".join(msg_parts)
        
        return {"changed": False, "msg": msg,
                "data": {"state": "OK", "metrics": {"uptime": uptime_sec}, "details": ""}}
    else:
        # Container is not running (exited, paused, etc.)
        return {"changed": False, "msg": "Operational state: " + status,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
