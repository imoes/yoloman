def main(ctx, params):
    # Read the raw agent section data
    res = ctx.run(["type", "C:\\ProgramData\\checkmk\\agent\\lib\\winperf\\winperf_ts_sessions"], mutates=False)
    # If file doesn't exist or is empty, try alternative path
    if res.rc != 0 or not res.stdout.strip():
        res = ctx.run(["type", "C:\\Program Files (x86)\\checkmk\\service\\winperf_ts_sessions"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        res = ctx.run(["type", "C:\\Program Files\\checkmk\\service\\winperf_ts_sessions"], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "Performance counters not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the output - example format:
    # 1385714515.93 2102
    # 2 20 rawcount
    # 4 18 rawcount
    # 6 2 rawcount
    lines = res.stdout.splitlines()
    if len(lines) < 4:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "Performance counters not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract counter values with guarded parsing
    parts1 = lines[1].split()
    parts2 = lines[2].split()
    parts3 = lines[3].split()
    
    if len(parts1) < 2 or len(parts2) < 2 or len(parts3) < 2:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "Performance counters not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    val1_str = parts1[1]
    val2_str = parts2[1]
    val3_str = parts3[1]
    
    if not val1_str.isdigit() or not val2_str.isdigit() or not val3_str.isdigit():
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {"changed": False, "msg": "Performance counters not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    total = int(val1_str)
    active = int(val2_str)
    inactive = int(val3_str)
    
    # Tom Moore's note: order may be active, inactive, total in newer Windows versions
    if active + inactive != total:
        active, inactive, total = total, active, inactive
    
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [
            {"item": "", "params": {}, "metrics": ["active", "inactive"]}
        ]}}
    
    # Apply thresholds (no thresholds defined in default params)
    active_warn = params.get("active", None)
    active_crit = None
    inactive_warn = params.get("inactive", None)
    inactive_crit = None
    
    # Determine state for active sessions
    active_state = "OK"
    if active_crit != None and active >= active_crit:
        active_state = "CRIT"
    elif active_warn != None and active >= active_warn:
        active_state = "WARN"
    
    # Determine state for inactive sessions
    inactive_state = "OK"
    if inactive_crit != None and inactive >= inactive_crit:
        inactive_state = "CRIT"
    elif inactive_warn != None and inactive >= inactive_warn:
        inactive_state = "WARN"
    
    # Final state is worst of the two
    final_state = "OK"
    if active_state == "CRIT" or inactive_state == "CRIT":
        final_state = "CRIT"
    elif active_state == "WARN" or inactive_state == "WARN":
        final_state = "WARN"
    
    msg = "%d Active, %d Inactive" % (active, inactive)
    
    return {"changed": False, "msg": msg,
            "data": {"state": final_state, "metrics": {"active": active, "inactive": inactive}, "details": ""}}
