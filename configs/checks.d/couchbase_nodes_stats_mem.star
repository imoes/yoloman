def main(ctx, params):
    # Constants (top level, as required)
    MEMORY_DEFAULT_LEVELS = {"levels": (150.0, 200.0)}
    
    # Determine mode
    warn, crit = MEMORY_DEFAULT_LEVELS.get("levels", (150.0, 200.0))
    user_levels = params.get("levels", (None, None))
    if user_levels != (None, None):
        warn, crit = user_levels
    
    # Check if discovery mode
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "-u", params.get("api_user", "admin") + ":" + params.get("api_password", ""), 
                       "http://" + params.get("host", "localhost") + ":8091/pools/default/nodeServices"], 
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch node services: " + res.stderr,
                    "data": {"discovery": []}}
        
        if res.stdout == "":
            return {"changed": False, "msg": "empty response from node services API",
                    "data": {"discovery": []}}
        
        services = json.decode(res.stdout)
        
        nodes = []
        for service in services.get("nodesExt", []):
            node = service.get("hostname", "")
            if node:
                nodes.append({"item": node, "params": {"levels": (150.0, 200.0)},
                              "metrics": ["mem_used", "swap_used"]})
        return {"changed": False, "msg": "discovered %d nodes" % len(nodes),
                "data": {"discovery": nodes}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run(["curl", "-s", "-u", params.get("api_user", "admin") + ":" + params.get("api_password", ""),
                   "http://" + params.get("host", "localhost") + ":8091/pools/default/nodes/" + item], 
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch node stats for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if res.stdout == "":
        return {"changed": False, "msg": "empty response from node stats API for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    
    # Check required fields exist
    mem_total = data.get("memoryTotal")
    mem_free = data.get("memoryFree")
    swap_total = data.get("swapTotal")
    swap_used = data.get("swapUsed")
    
    if mem_total == None or mem_free == None or swap_total == None or swap_used == None:
        return {"changed": False, "msg": "missing memory/swap data for node " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Convert to numbers safely (no try/except)
    def to_float(v):
        s = str(v)
        # Remove leading/trailing whitespace and check for valid number
        s = s.strip()
        # Check if it's a valid number string
        valid = True
        if s == "":
            valid = False
        else:
            has_dot = False
            has_digit = False
            for i in range(len(s)):
                c = s[i]
                if c == '-' and i == 0:
                    continue
                elif c == '.':
                    if has_dot:
                        valid = False
                        break
                    has_dot = True
                elif c >= '0' and c <= '9':
                    has_digit = True
                else:
                    valid = False
                    break
            if not has_digit:
                valid = False
        return float(s) if valid else 0.0
    
    mem_total = to_float(mem_total)
    mem_free = to_float(mem_free)
    swap_total = to_float(swap_total)
    swap_used = to_float(swap_used)
    
    # RAM check
    ram_used = mem_total - mem_free
    mode = "abs_used" if isinstance(warn, int) else "perc_used"
    
    if mode == "abs_used":
        warn_abs = warn
        crit_abs = crit
        if warn_abs != None and ram_used >= warn_abs:
            ram_state = "WARN"
        elif crit_abs != None and ram_used >= crit_abs:
            ram_state = "CRIT"
        else:
            ram_state = "OK"
    else:  # perc_used
        if mem_total > 0:
            ram_used_pct = (ram_used / mem_total) * 100.0
        else:
            ram_used_pct = 0.0
        warn_abs = warn
        crit_abs = crit
        if warn_abs != None and ram_used_pct >= warn_abs:
            ram_state = "WARN"
        elif crit_abs != None and ram_used_pct >= crit_abs:
            ram_state = "CRIT"
        else:
            ram_state = "OK"
    
    # Swap check (always absolute)
    swap_state = "OK"
    if swap_total > 0:
        swap_pct = (swap_used / swap_total) * 100.0
    else:
        swap_pct = 0.0
    
    # In Checkmk, swap has no levels by default, so we just report the value
    # For our implementation, we report swap as-is
    # We'll mark CRIT if swap_used is suspiciously high (>80% of swap_total)
    if swap_total > 0 and swap_pct > 80.0:
        swap_state = "CRIT"
    elif swap_total > 0 and swap_pct > 50.0:
        swap_state = "WARN"
    
    # Determine overall state
    if ram_state == "CRIT" or swap_state == "CRIT":
        state = "CRIT"
    elif ram_state == "WARN" or swap_state == "WARN":
        state = "WARN"
    else:
        state = "OK"
    
    # Build message and metrics
    if mode == "abs_used":
        ram_msg = "RAM used: %f MB" % (ram_used / 1048576)
        ram_val = ram_used / 1048576
    else:
        ram_msg = "RAM used: %f%%" % ram_used_pct
        ram_val = ram_used_pct
    
    swap_msg = "Swap used: %f MB" % (swap_used / 1048576)
    swap_val = swap_used / 1048576
    
    return {"changed": False,
            "msg": "%s, %s" % (ram_msg, swap_msg),
            "data": {
                "state": state,
                "metrics": {"mem_used": ram_val, "swap_used": swap_val},
                "details": "",
            },
        }
