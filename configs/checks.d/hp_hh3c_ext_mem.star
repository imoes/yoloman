def main(ctx, params):
    # Checkmk check: hp_hh3c_ext_mem
    # Read-only: gather SNMP data and compute memory usage metrics
    
    # Determine mode: discovery or check
    if params.get("_discover"):
        # Discovery: enumerate all items with mem_total > 0
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.25506.2.6.1.1.1.1"
        ], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "SNMP walk failed or empty",
                    "data": {"discovery": []}}
        
        # Parse discovery data: index admin_state oper_state cpu mem_usage temperature mem_size
        items = []
        for line in res.stdout.strip().split("\n"):
            if "=" not in line:
                continue
            oid_part, value_part = line.split("=", 1)
            index = oid_part.strip().split(".")[-1]
            value = value_part.strip()
            parts = value.split()
            if len(parts) < 7:
                continue
            admin_state, oper_state, cpu, mem_usage, temperature, mem_size = parts[1:7]
            mem_total = int(mem_size)
            # Skip items with mem_total <= 0 (not installed or invalid)
            if mem_total <= 0:
                continue
            item_name = index  # Checkmk uses index as item for this check
            items.append({
                "item": item_name,
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["memused", "memused_percent"]
            })
        return {
            "changed": False,
            "msg": "discovered %d memory modules" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get base table data: .1.3.6.1.4.1.25506.2.6.1.1.1.1
    # OIDs: .1 (index), .2 (admin), .3 (oper), .6 (cpu), .8 (mem_usage), .12 (temperature), .10 (mem_size)
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.25506.2.6.1.1.1.1." + item
    ], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse snmpget response: OID = TYPE: value
    value_line = res.stdout.strip()
    if "=" not in value_line:
        return {"changed": False, "msg": "invalid SNMP response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract value portion
    value = value_line.split(":", 1)[1].strip()
    parts = value.split()
    if len(parts) < 7:
        return {"changed": False, "msg": "invalid value format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    admin_state, oper_state, cpu, mem_usage, temperature, mem_size = parts[1:7]
    
    # Guard against non-numeric values
    if not mem_size.isdigit() or not mem_usage.isdigit():
        return {"changed": False, "msg": "invalid numeric values",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Compute memory values
    mem_total = int(mem_size)
    mem_usage_percent = int(mem_usage)
    
    # Skip items with mem_total <= 0
    if mem_total <= 0:
        return {"changed": False, "msg": "module not installed or invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    mem_used = 0.01 * mem_usage_percent * mem_total
    
    # Get thresholds
    levels = params.get("levels")
    warn_pct = None
    crit_pct = None
    warn_abs = None
    crit_abs = None
    
    if levels == None:
        warn_pct, crit_pct = 80.0, 90.0
    elif isinstance(levels, list) and len(levels) == 2:
        # Check if first element is int (absolute) or float (percent)
        first = levels[0]
        if isinstance(first, int):
            warn_abs, crit_abs = levels[0], levels[1]
        else:
            warn_pct, crit_pct = levels[0], levels[1]
    else:
        warn_pct, crit_pct = 80.0, 90.0
    
    # Compute state
    state = "OK"
    
    # Percent check
    if warn_pct != None:
        if mem_usage_percent >= crit_pct:
            state = "CRIT"
        elif mem_usage_percent >= warn_pct and state != "CRIT":
            state = "WARN"
    # Absolute check
    if warn_abs != None:
        if mem_used >= crit_abs:
            state = "CRIT"
        elif mem_used >= warn_abs and state != "CRIT":
            state = "WARN"
    
    # Build message
    mem_used_mb = mem_used / (1024.0 * 1024.0)
    msg = "Size: %f MB; Usage: %f%%" % (mem_used_mb, mem_usage_percent)
    
    metrics = {
        "memused": mem_used,
        "memused_percent": mem_usage_percent,
    }
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }