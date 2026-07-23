def main(ctx, params):
    # Determine mode: discovery or check
    if params.get("_discover"):
        # Discovery: check if this host is a FortiMail device using SNMP
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
                      mutates=False)
        if res.rc != 0:
            # Cannot determine device type; return empty discovery
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Check for FortiMail OID: .1.3.6.1.4.1.12356.105
        sysoid = None
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                oid_val = parts[1].strip()
                if oid_val.startswith("STRING: ") and ".1.3.6.1.4.1.12356.105" in oid_val:
                    sysoid = oid_val.replace("STRING: ", "")
                    break
                elif oid_val == ".1.3.6.1.4.1.12356.105":
                    sysoid = ".1.3.6.1.4.1.12356.105"
                    break
        
        if sysoid != ".1.3.6.1.4.1.12356.105":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Device is FortiMail; discovery yields one service
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {"cpu_load": None},
                                        "metrics": ["load_instant"]}]}}
    
    # Check mode
    # Fetch CPU load via SNMP
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), ".1.3.6.1.4.1.12356.105.1.30"],
                  mutates=False)
    
    if res.rc != 0 or " = " not in res.stdout:
        return {"changed": False, "msg": "cannot read CPU load",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse value: expected format ".1.3.6.1.4.1.12356.105.1.30.0 = INTEGER: 5"
    line = res.stdout.strip()
    parts = line.split(" = ")
    if len(parts) != 2:
        return {"changed": False, "msg": "cannot parse CPU load value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_str = parts[1].strip()
    # Remove possible prefix like "INTEGER: " or "Gauge32: "
    for prefix in ["INTEGER: ", "Gauge32: ", "Integer32: "]:
        if value_str.startswith(prefix):
            value_str = value_str[len(prefix):]
            break
    
    # Guard: only parse if the remaining string is numeric
    cpu_load = 0.0
    if value_str.isdigit() or (value_str.count(".") == 1 and value_str.replace(".", "").isdigit()):
        cpu_load = float(value_str)
    else:
        return {"changed": False, "msg": "cannot parse CPU load value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract thresholds
    levels = params.get("cpu_load")
    warn, crit = None, None
    if levels != None and type(levels) == "list" and len(levels) >= 2:
        warn = float(levels[0])
        crit = float(levels[1])
    
    # Determine state based on upper levels (warn/crit thresholds)
    state = "OK"
    if crit != None and cpu_load >= crit:
        state = "CRIT"
    elif warn != None and cpu_load >= warn:
        state = "WARN"
    
    msg = "CPU load: %f" % cpu_load
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"load_instant": cpu_load},
                     "details": ""}}
