def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: list all single_file entries from the filestats agent section
        res = ctx.run(["cat", "/var/lib/check-mk-agent/local/filestats"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            # No filestats data available - return empty discovery
            return {"changed": False, "msg": "discovered 0 files", "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            if not line:
                continue
            # Guard: only decode non-empty lines
            entry = json.decode(line)
            if entry != None and entry.get("type") == "single_file":
                item_val = entry.get("item", "")
                if item_val:
                    items.append({
                        "item": item_val,
                        "params": {},
                        "metrics": ["size", "age"]
                    })
        
        return {"changed": False, "msg": "discovered %d single files" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: check a single file item
    item = params.get("item", "")
    
    res = ctx.run(["cat", "/var/lib/check-mk-agent/local/filestats"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data available", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    single_stat = None
    for line in res.stdout.splitlines():
        if not line:
            continue
        # Guard: only decode non-empty lines
        entry = json.decode(line)
        if entry != None and entry.get("item") == item and entry.get("type") == "file":
            single_stat = entry
            break
    
    if single_stat == None:
        return {"changed": False, "msg": "item not found: " + item, "data": {
            "state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Check if status is not available
    if single_stat.get("size") == None and single_stat.get("age") == None:
        status_val = single_stat.get("stat_status", "unknown")
        return {"changed": False, "msg": "Status: " + str(status_val), "data": {
            "state": "OK", "metrics": {}, "details": ""}}
    
    # Get parameters for thresholds
    max_size = params.get("max_size", (None, None))
    min_size = params.get("min_size", (None, None))
    max_age = params.get("max_age", (None, None))
    min_age = params.get("min_age", (None, None))
    
    # Helper to determine state from levels
    def check_levels(value, levels_upper, levels_lower):
        if value == None:
            return "OK"
        
        upper_warn_val = levels_upper[0] if levels_upper != None and len(levels_upper) > 0 else None
        upper_crit_val = levels_upper[1] if levels_upper != None and len(levels_upper) > 1 else None
        lower_warn_val = levels_lower[0] if levels_lower != None and len(levels_lower) > 0 else None
        lower_crit_val = levels_lower[1] if levels_lower != None and len(levels_lower) > 1 else None
        
        # Check upper levels first
        if upper_crit_val != None and value >= upper_crit_val:
            return "CRIT"
        if upper_warn_val != None and value >= upper_warn_val:
            return "WARN"
        
        # Check lower levels
        if lower_crit_val != None and value <= lower_crit_val:
            return "CRIT"
        if lower_warn_val != None and value <= lower_warn_val:
            return "WARN"
        
        return "OK"
    
    # Helper to render size (bytes to human readable)
    def render_size(value):
        if value == None:
            return "0 B"
        units = ["B", "KB", "MB", "GB", "TB"]
        unit_index = 0
        while value >= 1024 and unit_index < len(units)-1:
            value = value / 1024.0
            unit_index = unit_index + 1
        return "%f %s" % (value, units[unit_index])
    
    # Helper to render age (seconds to human readable)
    def render_age(value):
        if value == None:
            return "0 s"
        
        value = int(value)
        if value < 60:
            return "%d s" % value
        elif value < 3600:
            return "%d min %d s" % (value // 60, value % 60)
        elif value < 86400:
            days_val = value // 86400
            hours_val = (value % 86400) // 3600
            return "%d d %d h" % (days_val, hours_val)
        else:
            return "%d s" % value
    
    state = "OK"
    metrics = {}
    details_parts = []
    
    # Check size
    if single_stat.get("size") != None:
        value = single_stat["size"]
        size_state = check_levels(value, max_size, min_size)
        if size_state != "OK":
            state = size_state
        metrics["size"] = value
        details_parts.append("Size: " + render_size(value))
    
    # Check age
    if single_stat.get("age") != None:
        value = single_stat["age"]
        age_state = check_levels(value, max_age, min_age)
        if age_state != "OK":
            state = age_state
        metrics["age"] = value
        details_parts.append("Age: " + render_age(value))
    
    summary = ", ".join(details_parts) if details_parts else "No metrics"
    if state == "OK":
        summary = "OK: " + summary
    
    return {"changed": False, "msg": summary, "data": {
        "state": state, "metrics": metrics, "details": ""}}
