def main(ctx, params):
    # SNMP OID base for blank tapes count (section index 5, OID .1.3.6.1.4.1.110901.1.4.3.0)
    base_oid = ".1.3.6.1.4.1.110901.1.4.3.0"
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discovery mode: check if blank tapes data exists
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid
        ], mutates=False)
        
        # Blank tapes section exists if we get any output
        if res.stdout and res.rc == 0 and len(res.stdout.strip()) > 0:
            return {
                "changed": False,
                "msg": "discovered DIVA Blank Tapes service",
                "data": {"discovery": [{"item": "", "params": {"levels_lower": (5, 1)}, "metrics": ["tapes_free"]}]}
            }
        else:
            return {
                "changed": False,
                "msg": "no DIVA blank tapes data available",
                "data": {"discovery": []}
            }
    
    # Check mode: fetch blank tapes count
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, base_oid
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "unable to retrieve blank tapes count",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Parse snmpget output: ".1.3.6.1.4.1.110901.1.4.3.0 = INTEGER: 5"
    line = res.stdout.strip()
    parts = line.split(" = ")
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "unable to parse blank tapes count",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    value_part = parts[1]
    if not value_part.startswith("INTEGER:"):
        return {
            "changed": False,
            "msg": "unexpected SNMP response format for blank tapes",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Extract integer value with guard instead of try/except
    val_str = value_part.split(":")[1].strip()
    blank_tapes = int(val_str) if val_str.isdigit() else -1
    
    if blank_tapes < 0:
        return {
            "changed": False,
            "msg": "unable to parse blank tapes count as integer",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Apply levels (lower levels: warn if <= warn, crit if <= crit)
    levels_lower = params.get("levels_lower", [5, 1])
    warn = levels_lower[0] if levels_lower else None
    crit = levels_lower[1] if levels_lower else None
    
    # Determine state based on levels (lower thresholds)
    state = "OK"
    
    if crit != None and blank_tapes <= crit:
        state = "CRIT"
    elif warn != None and blank_tapes <= warn:
        state = "WARN"
    
    # Build summary message
    summary = "Blank tapes: %d" % blank_tapes
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"tapes_free": blank_tapes},
            "details": ""
        }
    }