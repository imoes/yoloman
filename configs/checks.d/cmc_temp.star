def main(ctx, params):
    # Checkmk defaults
    warn_default = 45.0
    crit_default = 50.0
    
    # SNMP section OIDs
    base_current = ".1.3.6.1.4.1.2606.1.1"
    base_dev = ".1.3.6.1.4.1.2606.1.4"
    oid_current = [base_current + ".1", base_current + ".2"]
    oid_dev_high = [base_dev + ".4", base_dev + ".6"]
    oid_dev_low = [base_dev + ".5", base_dev + ".7"]
    
    if params.get("_discover"):
        # Discovery: always two sensors
        items = [
            {"item": "1", "params": {"levels": (warn_default, crit_default)}, "metrics": ["temperature"]},
            {"item": "2", "params": {"levels": (warn_default, crit_default)}, "metrics": ["temperature"]}
        ]
        return {"changed": False, "msg": "discovered 2 temperature sensors",
                "data": {"discovery": items}}
    
    item = params.get("item", "1")
    # Convert item to index (0 or 1) - guard before risky conversion
    idx = 0
    if item.isdigit() and int(item) >= 1 and int(item) <= 2:
        idx = int(item) - 1
    
    # Gather temperature data via SNMP walk
    # For sensor index idx, get current temp from oid_current[idx]
    # and dev high/low from oid_dev_high[idx] and oid_dev_low[idx]
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    current_oid = oid_current[idx]
    dev_high_oid = oid_dev_high[idx]
    dev_low_oid = oid_dev_low[idx]
    
    # Fetch current temperature
    res_current = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, current_oid
    ], mutates=False)
    if res_current.rc != 0 or not res_current.stdout.strip():
        return {
            "changed": False,
            "msg": "SNMP error or no data for sensor %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse current temp: output format: ".1.3.6.1.4.1.2606.1.1.1.0 = INTEGER: 26"
    current_line = res_current.stdout.strip()
    if current_line.find("INTEGER:") == -1:
        return {
            "changed": False,
            "msg": "unable to parse current temp value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    parts = current_line.split("INTEGER:")
    current_temp_str = parts[-1].strip() if len(parts) > 1 else ""
    current_temp = 0
    if current_temp_str.isdigit():
        current_temp = int(current_temp_str)
    
    # Fetch dev high
    res_high = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, dev_high_oid
    ], mutates=False)
    dev_high = None
    if res_high.rc == 0 and res_high.stdout.strip():
        high_line = res_high.stdout.strip()
        if high_line.find("INTEGER:") != -1:
            high_parts = high_line.split("INTEGER:")
            high_str = high_parts[-1].strip() if len(high_parts) > 1 else ""
            if high_str.isdigit():
                dev_high = int(high_str)
    
    # Fetch dev low
    res_low = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, dev_low_oid
    ], mutates=False)
    dev_low = None
    if res_low.rc == 0 and res_low.stdout.strip():
        low_line = res_low.stdout.strip()
        if low_line.find("INTEGER:") != -1:
            low_parts = low_line.split("INTEGER:")
            low_str = low_parts[-1].strip() if len(low_parts) > 1 else ""
            if low_str.isdigit():
                dev_low = int(low_str)
    
    # Get thresholds from params or defaults
    levels = params.get("levels")
    warn = warn_default
    crit = crit_default
    if levels != None and type(levels) == "list":
        if len(levels) >= 2:
            warn = float(levels[0])
            crit = float(levels[1])
    
    # Apply threshold logic (same as Checkmk's check_temperature for upper levels)
    state = "OK"
    if current_temp >= crit:
        state = "CRIT"
    elif current_temp >= warn:
        state = "WARN"
    
    # Format message in Checkmk style
    msg = "Sensor %s: %d C" % (item, current_temp)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": float(current_temp)},
            "details": ""
        }
    }
