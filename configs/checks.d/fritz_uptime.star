def _parse_uptime_value(output):
    start = output.find("<NewUptime>")
    if start == -1:
        return None
    start += len("<NewUptime>")
    end = output.find("</NewUptime>", start)
    if end == -1:
        return None
    val = output[start:end]
    if not val.isdigit():
        return None
    return val

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "-k", "https://fritz.box:49443/upnp/control/base"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items (HTTP fetch failed)",
                    "data": {"discovery": []}}
        uptime_str = _parse_uptime_value(res.stdout)
        if uptime_str == None:
            return {"changed": False, "msg": "discovered 0 items (no uptime data in response)",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["uptime"]}]}}
    
    res = ctx.run(["curl", "-s", "-k", "https://fritz.box:49443/upnp/control/base"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "uptime data unavailable (HTTP fetch failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    uptime_str = _parse_uptime_value(res.stdout)
    if uptime_str == None:
        return {"changed": False, "msg": "uptime data unavailable (parsing failed)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    uptime_sec = float(uptime_str)
    
    # Get current timestamp via /proc/uptime if available, otherwise assume now
    current_sec = 0.0
    if ctx.file_exists("/proc/uptime"):
        content = ctx.file_read("/proc/uptime")
        parts = content.split()
        if len(parts) >= 1 and parts[0].isdigit():
            current_sec = float(parts[0])
    else:
        # Fallback: use system date command
        date_res = ctx.run(["date", "+%s"], mutates=False)
        if date_res.rc == 0 and date_res.stdout.strip().isdigit():
            current_sec = float(date_res.stdout.strip())
    
    if current_sec == 0.0:
        return {"changed": False, "msg": "uptime data unavailable (cannot determine current time)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    age = int(current_sec - uptime_sec)
    
    # Default thresholds from Checkmk: warn_below=86400 (1d), crit_below=43200 (12h)
    warn = params.get("levels", (86400, 43200))[0]
    crit = params.get("levels", (86400, 43200))[1]
    
    state = "OK"
    if age <= crit:
        state = "CRIT"
    elif age <= warn:
        state = "WARN"
    
    days = int(age // 86400)
    hours = int((age % 86400) // 3600)
    minutes = int((age % 3600) // 60)
    duration_str = "%d d %d h %d m" % (days, hours, minutes)
    
    return {"changed": False, "msg": "Uptime: %s, Age: %s" % (uptime_str, duration_str),
            "data": {"state": state, "metrics": {"uptime": uptime_sec}, "details": ""}}