def main(ctx, params):
    if params.get("_discover"):
        meminfo = ctx.file_read("/proc/meminfo") if ctx.file_exists("/proc/meminfo") else ""
        if meminfo == "":
            return {"changed": False, "msg": "not a Linux host", "data": {"discovery": []}}
        lines = meminfo.splitlines()
        total = 0
        avail = 0
        have_total = False
        have_avail = False
        for line in lines:
            parts = line.split()
            if len(parts) < 2:
                continue
            key = parts[0]
            val = int(parts[1]) if parts[1].isdigit() else 0
            if key == "MemTotal:":
                total = val
                have_total = True
            elif key == "MemAvailable:":
                avail = val
                have_avail = True
        if not have_total or not have_avail:
            return {"changed": False, "msg": "not a Linux host", "data": {"discovery": []}}
        discovery = [{"item": "", "params": {"levels": ("fixed", (70.0, 80.0))}, "metrics": ["mem_used_percent"]}]
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": discovery}}
    meminfo = ctx.file_read("/proc/meminfo") if ctx.file_exists("/proc/meminfo") else ""
    if meminfo == "":
        return {"changed": False, "msg": "no memory information found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = meminfo.splitlines()
    total = 0
    avail = 0
    have_total = False
    have_avail = False
    for line in lines:
        parts = line.split()
        if len(parts) < 2:
            continue
        key = parts[0]
        val = int(parts[1]) if parts[1].isdigit() else 0
        if key == "MemTotal:":
            total = val
            have_total = True
        elif key == "MemAvailable:":
            avail = val
            have_avail = True
    if not have_total or not have_avail or total == 0:
        return {"changed": False, "msg": "no memory information found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    used = total - avail
    pct = (used * 100.0) / total
    levels = params.get("levels", ("fixed", (70.0, 80.0)))
    warn = 70.0
    crit = 80.0
    if type(levels) == "list" and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    elif type(levels) == "tuple" and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    elif type(levels) == "dict":
        wl = levels.get("warn", levels.get("warning"))
        cl = levels.get("crit", levels.get("critical"))
        if wl != None:
            warn = wl
        if cl != None:
            crit = cl
    elif type(levels) == "list" and len(levels) == 2 and levels[0] == "fixed":
        warn = levels[1][0]
        crit = levels[1][1]
    state = "CRIT" if pct >= crit else ("WARN" if pct >= warn else "OK")
    return {"changed": False, "msg": "Memory utilization: %s%% used" % ("%f" % pct), "data": {"state": state, "metrics": {"mem_used_percent": pct}, "details": "total=%s available=%s used=%s pct=%f%% warn=%f%% crit=%f%%" % (total, avail, used, pct, warn, crit)}}