def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lvs", "--noheadings", "--options", "vg_name,pv_count,lv_count,snap_count,vg_attr,vg_size,vg_free", "--units", "b", "--nosuffix"], mutates=False)
        out = []
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 7:
                continue
            vg_name = parts[0]
            size_str = parts[5]
            free_str = parts[6]
            if not size_str.isdigit() or not free_str.isdigit():
                continue
            vg_size = int(size_str)
            vg_free = int(free_str)
            size_mb = vg_size // (1024 * 1024)
            free_mb = vg_free // (1024 * 1024)
            if size_mb > 0:
                out.append({"item": vg_name, "params": {}, "metrics": ["size", "free"]})
        return {"changed": False, "msg": "discovered %d volume groups" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["lvs", "--noheadings", "--select", "vg_name=" + item, "--options", "vg_name,pv_count,lv_count,snap_count,vg_attr,vg_size,vg_free", "--units", "b", "--nosuffix"], mutates=False)
    lines = res.stdout.strip().splitlines()
    if not lines or len(lines) == 0 or lines[0].strip() == "":
        return {"changed": False, "msg": "volume group '%s' not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts = lines[0].strip().split()
    if len(parts) < 7:
        return {"changed": False, "msg": "could not parse data for VG '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    size_str = parts[5]
    free_str = parts[6]
    if not size_str.isdigit() or not free_str.isdigit():
        return {"changed": False, "msg": "could not parse size/free values for VG '%s'" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    vg_size = int(size_str)
    vg_free = int(free_str)
    size_mb = vg_size // (1024 * 1024)
    free_mb = vg_free // (1024 * 1024)
    used_mb = size_mb - free_mb
    
    # Avoid division by zero
    used_percent = 0.0
    if size_mb > 0:
        used_percent = (float(used_mb) / float(size_mb)) * 100.0
    
    # Extract thresholds from params (Checkmk's FILESYSTEM_DEFAULT_PARAMS)
    warn = 80.0
    crit = 90.0
    
    levels = params.get("levels")
    if levels != None:
        if type(levels) == "list" and len(levels) >= 2:
            warn = float(levels[0])
            crit = float(levels[1])
    
    warn_param = params.get("warn")
    if warn_param != None:
        warn = float(warn_param)
    
    crit_param = params.get("crit")
    if crit_param != None:
        crit = float(crit_param)
    
    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    
    msg = "%s Size: %f MB, Used: %f MB (%f%%)" % (item, float(size_mb), float(used_mb), used_percent)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"size": size_mb, "free": free_mb, "used": used_mb, "used_percent": used_percent}, "details": ""}}