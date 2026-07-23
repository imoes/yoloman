# Module-level constants
MIB = 1024.0 * 1024.0

def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        res = ctx.run(["ceph", "osd", "bluefs", "show", "--format", "json"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch bluefs data", 
                    "data": {"discovery": []}}
        
        if not res.stdout:
            return {"changed": False, "msg": "no bluefs data available", 
                    "data": {"discovery": []}}
        
        data = json.decode(res.stdout)
        if type(data) != "dict":
            return {"changed": False, "msg": "unexpected bluefs data format", 
                    "data": {"discovery": []}}
        
        items = []
        for osdid, entry in data.items():
            if type(entry) != "dict":
                continue
            bluefs = entry.get("bluefs")
            if bluefs == None or type(bluefs) != "dict":
                continue
            
            db_total_mb = float(bluefs.get("db_total_bytes", 0)) / MIB
            if db_total_mb > 0:
                items.append({
                    "item": osdid,
                    "params": {},
                    "metrics": ["used_percent"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d OSDs with DB" % len(items),
            "data": {"discovery": items}
        }
    
    # CHECK MODE (per-item)
    item = params.get("item", "")
    
    # Get data
    res = ctx.run(["ceph", "osd", "bluefs", "show", "--format", "json"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to fetch bluefs data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if not res.stdout:
        return {
            "changed": False,
            "msg": "no bluefs data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    data = json.decode(res.stdout)
    if type(data) != "dict":
        return {
            "changed": False,
            "msg": "failed to parse bluefs JSON",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check item exists
    if item not in data:
        return {
            "changed": False,
            "msg": "OSD %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    entry = data.get(item, {})
    if type(entry) != "dict":
        return {
            "changed": False,
            "msg": "OSD %s entry has invalid format" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    bluefs = entry.get("bluefs")
    if type(bluefs) != "dict":
        return {
            "changed": False,
            "msg": "OSD %s has no bluefs data" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract values
    db_total_mb = float(bluefs.get("db_total_bytes", 0)) / MIB
    db_used_mb = float(bluefs.get("db_used_bytes", 0)) / MIB
    
    if db_total_mb <= 0:
        return {
            "changed": False,
            "msg": "OSD %s DB total size is zero" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    db_avail_mb = db_total_mb - db_used_mb
    
    # Extract params
    warn = 80.0
    crit = 90.0
    levels = params.get("levels")
    if levels != None:
        if type(levels) == "list" and len(levels) >= 2:
            warn = float(levels[0])
            crit = float(levels[1])
        elif type(levels) == "list" and len(levels) == 1:
            warn = float(levels[0])
    
    # Calculate percentages
    used_percent = (db_used_mb / db_total_mb) * 100.0
    
    # Determine state
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    msg = "Size: %f MB, Used: %f%%" % (db_total_mb, used_percent)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "size": db_total_mb,
                "used": db_used_mb,
                "avail": db_avail_mb
            },
            "details": ""
        }
    }
