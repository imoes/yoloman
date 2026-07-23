def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        path = "/var/lib/appdynamics/appdynamics_sessions"
        if not ctx.file_exists(path):
            return {"changed": False, "msg": "discovered 0 items (data not available)",
                    "data": {"discovery": []}}
        
        content = ctx.file_read(path)
        lines = content.strip().split("\n")
        items = []
        for line in lines:
            if not line:
                continue
            parts = line.split("|")
            if len(parts) >= 2:
                item_name = parts[0] + " " + parts[1]
                items.append({"item": item_name, "params": {}, "metrics": ["running_sessions", "rejected_sessions"]})
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    path = "/var/lib/appdynamics/appdynamics_sessions"
    if not ctx.file_exists(path):
        return {"changed": False, "msg": "data file not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    content = ctx.file_read(path)
    lines = content.strip().split("\n")
    found = False
    values = {}
    
    for line in lines:
        if not line:
            continue
        parts = line.split("|")
        if len(parts) >= 2 and item == parts[0] + " " + parts[1]:
            found = True
            for metric in parts[2:]:
                if ":" in metric:
                    idx = metric.find(":")
                    name = metric[0:idx]
                    val_str = metric[idx+1:]
                    # Guard instead of try/except
                    if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                        values[name] = int(val_str)
                    else:
                        values[name] = 0
    
    if not found:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if "activeSessions" not in values:
        return {"changed": False, "msg": "missing activeSessions data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    active = values["activeSessions"]
    rejected = values.get("rejectedSessions", 0)
    max_active = values.get("maxActive", 0)
    counter = values.get("sessionCounter", 0)
    
    # Threshold logic
    state = "OK"
    
    # Check upper levels
    warn_upper = params.get("levels_upper")
    crit_upper = params.get("levels_upper")
    
    if warn_upper != None:
        if type(warn_upper) == "list" and len(warn_upper) >= 2:
            warn_val = warn_upper[1]
            if warn_val != None:
                if active >= warn_val:
                    state = "WARN"
    
    if crit_upper != None:
        if type(crit_upper) == "list" and len(crit_upper) >= 2:
            crit_val = crit_upper[1]
            if crit_val != None:
                if active >= crit_val:
                    state = "CRIT"
    
    # Check lower levels (only if still OK)
    if state == "OK":
        warn_lower = params.get("levels_lower")
        crit_lower = params.get("levels_lower")
        
        if warn_lower != None:
            if type(warn_lower) == "list" and len(warn_lower) >= 2:
                warn_val = warn_lower[1]
                if warn_val != None:
                    if active <= warn_val:
                        state = "WARN"
        
        if crit_lower != None:
            if type(crit_lower) == "list" and len(crit_lower) >= 2:
                crit_val = crit_lower[1]
                if crit_val != None:
                    if active <= crit_val:
                        state = "CRIT"
    
    msg_parts = ["Running sessions: %d" % active, "Rejected: %d" % rejected, "Maximum active: %d" % max_active]
    summary = ", ".join(msg_parts)
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, 
                     "metrics": {"running_sessions": active, "rejected_sessions": rejected},
                     "details": ""}}