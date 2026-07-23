def _parse_byte_values(value_str):
    # Strip trailing 'iB' if present
    if value_str.endswith("iB"):
        value_str = value_str[:-2]
    elif value_str.endswith("B"):
        value_str = value_str[:-1]
    
    # Handle unit suffixes (case-insensitive for 'k')
    if value_str.upper().endswith("E"):
        val = float(value_str[:-1])
        return val * 1024 * 1024 * 1024 * 1024
    if value_str.upper().endswith("P"):
        val = float(value_str[:-1])
        return val * 1024 * 1024 * 1024
    if value_str.upper().endswith("T"):
        val = float(value_str[:-1])
        return val * 1024 * 1024
    if value_str.upper().endswith("G"):
        val = float(value_str[:-1])
        return val * 1024
    if value_str.upper().endswith("M"):
        val = float(value_str[:-1])
        return val
    if value_str.lower().endswith("k"):
        val = float(value_str[:-1])
        return val / 1024
    if value_str == "N/A":
        return 0.0
    
    # Default case: parse as float, guard against errors
    try_val = float(value_str)
    return try_val / (1024 * 1024)

def main(ctx, params):
    if params.get("_discover"):
        # Discovery is disabled per original plugin
        return {"changed": False, "msg": "discovery disabled", "data": {"discovery": []}}
    
    item = params.get("item", "")
    
    # Run ceph df -f json to get structured output
    res = ctx.run(["ceph", "df", "-f", "json"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "ceph df command failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if res.stdout == "":
        return {"changed": False, "msg": "ceph df returned empty output", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    
    # Find the requested pool
    pool_data = None
    pools_list = data.get("pools")
    if pools_list != None:
        for pool in pools_list:
            if pool.get("name") == item:
                pool_data = pool
                break
    
    if pool_data == None:
        return {"changed": False, "msg": "pool '%s' not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract metrics
    used_str = pool_data.get("stored_bytes")
    if used_str == None:
        used_str = pool_data.get("used_bytes")
        if used_str == None:
            used_str = "0"
    
    stored_str = pool_data.get("stored")
    if stored_str == None:
        stored_str = pool_data.get("stored_bytes")
        if stored_str == None:
            stored_str = "0"
    
    avail_str = pool_data.get("max_avail")
    if avail_str == None:
        avail_str = pool_data.get("avail_bytes")
        if avail_str == None:
            avail_str = "0"
    
    used_mb = _parse_byte_values(str(used_str))
    stored_mb = _parse_byte_values(str(stored_str))
    avail_mb = _parse_byte_values(str(avail_str))
    
    # Total size = stored + avail (notional stored + available)
    size_mb = stored_mb + avail_mb
    
    # Calculate percentage used
    if size_mb > 0:
        used_percent = (used_mb / size_mb) * 100
    else:
        used_percent = 0.0
    
    # Get thresholds from params
    levels = params.get("levels")
    warn = 80
    crit = 90
    
    if levels != None:
        if type(levels) == "list":
            if len(levels) >= 2:
                warn = levels[0]
                crit = levels[1]
        elif type(levels) == "dict":
            warn = levels.get("warn", 80)
            crit = levels.get("crit", 90)
    
    # Determine state
    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    
    # Build message
    msg = "%s: %d MB used (%f%%)" % (item, used_mb, used_percent)
    
    # Return results
    return {"changed": False, "msg": msg, "data": {
        "state": state,
        "metrics": {
            "size": size_mb,
            "used": used_mb,
            "avail": avail_mb,
            "used_percent": used_percent
        },
        "details": ""
    }}