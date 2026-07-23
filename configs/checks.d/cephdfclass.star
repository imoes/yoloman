def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["ceph", "df", "--format", "json"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to get ceph df: " + res.stderr,
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "empty response from ceph df",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        
        classes = data.get("stats_by_class", {})
        out = []
        for cls in classes:
            out.append({"item": cls, "params": {}, "metrics": ["used_percent"]})
        return {"changed": False, "msg": "discovered %d ceph classes" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["ceph", "df", "--format", "json"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to get ceph df: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "empty response from ceph df",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    
    stats_by_class = data.get("stats_by_class", {})
    stats = stats_by_class.get(item)
    if stats == None:
        return {"changed": False, "msg": "ceph class not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    total_bytes = stats.get("total_bytes", 0)
    total_avail_bytes = stats.get("total_avail_bytes", 0)
    
    if total_bytes <= 0:
        size_mb = 0.0
        avail_mb = 0.0
        used_mb = 0.0
    else:
        size_mb = total_bytes / (1024.0 * 1024.0)
        avail_mb = total_avail_bytes / (1024.0 * 1024.0)
        used_mb = size_mb - avail_mb
    
    if size_mb <= 0:
        used_percent = 0.0
    else:
        used_percent = (used_mb / size_mb) * 100.0
    
    warn = params.get("levels", (80.0, 90.0))
    crit = params.get("levels", (80.0, 90.0))
    
    state = "OK"
    if used_percent >= crit[1]:
        state = "CRIT"
    elif used_percent >= crit[0]:
        state = "WARN"
    elif used_percent <= warn[1] and warn[1] > 0:
        state = "OK"
    elif used_percent <= warn[0] and warn[0] > 0:
        state = "OK"
    
    if state == "OK" and used_percent >= warn[0] and warn[0] > 0:
        state = "WARN"
    
    msg = "Size: %f MB, Used: %f MB (%f%%)" % (size_mb, used_mb, used_percent)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"used_percent": used_percent}, "details": ""}}
