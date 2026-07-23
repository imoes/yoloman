def main(ctx, params):
    # Constants
    BASE_OID = ".1.3.6.1.4.1.4555.1.1.1.1.3.3.1"
    DEFAULT_LEVELS_LOWER = (210.0, 180.0)
    
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), BASE_OID + ".1",
            BASE_OID + ".2"
        ], mutates=False)
        
        # Parse OID values
        lines = res.stdout.splitlines()
        items = []
        i = 0
        while i < len(lines):
            # Each iteration processes two lines: phase name and voltage
            if i + 1 < len(lines):
                line1 = lines[i].strip()
                line2 = lines[i + 1].strip()
                
                # Extract values: OID = TYPE: value
                parts1 = line1.split(" = ")
                parts2 = line2.split(" = ")
                if len(parts1) >= 2 and len(parts2) >= 2:
                    # Extract numeric value from second part
                    val2 = parts2[1].strip()
                    # Get numeric part (handle INTEGER: or Gauge32: etc.)
                    if val2.startswith("INTEGER:"):
                        raw_str = val2.split(":", 1)[1].strip()
                        voltage_raw = int(raw_str) if raw_str.isdigit() else -1
                        if voltage_raw > 0:
                            # Phase name extraction: get last number from OID
                            phase_oid = parts1[0].strip()
                            phase_num = phase_oid.rsplit(".", 1)[-1]
                            phase_name = "L" + phase_num if phase_num.isdigit() else phase_num
                            items.append({
                                "item": phase_name,
                                "params": {"levels_lower": DEFAULT_LEVELS_LOWER},
                                "metrics": ["in_voltage"]
                            })
                i += 2
            else:
                i += 1
        
        return {"changed": False, "msg": "discovered %d voltage phases" % len(items),
                "data": {"discovery": items}}
    
    # Check mode - single item
    item = params.get("item", "")
    levels_lower = params.get("levels_lower", DEFAULT_LEVELS_LOWER)
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), BASE_OID + ".1",
        BASE_OID + ".2"
    ], mutates=False)
    
    # Parse OID values to find matching item
    lines = res.stdout.splitlines()
    found_voltage = None
    i = 0
    while i < len(lines):
        if i + 1 < len(lines):
            line1 = lines[i].strip()
            line2 = lines[i + 1].strip()
            
            parts1 = line1.split(" = ")
            parts2 = line2.split(" = ")
            if len(parts1) >= 2 and len(parts2) >= 2:
                phase_oid = parts1[0].strip()
                val2 = parts2[1].strip()
                
                # Extract phase number from OID
                phase_num = phase_oid.rsplit(".", 1)[-1]
                phase_name = "L" + phase_num if phase_num.isdigit() else phase_num
                if phase_name == item:
                    if val2.startswith("INTEGER:"):
                        raw_str = val2.split(":", 1)[1].strip()
                        if raw_str.isdigit():
                            found_voltage = int(raw_str) / 10.0
                            break
        i += 2
    
    if found_voltage == None:
        return {"changed": False, "msg": "phase %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply thresholds (lower levels)
    state = "OK"
    warn_val, crit_val = levels_lower[0], levels_lower[1]
    
    if found_voltage <= crit_val:
        state = "CRIT"
    elif found_voltage <= warn_val:
        state = "WARN"
    
    msg = "Phase %s: %f V" % (item, found_voltage)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"in_voltage": found_voltage},
            "details": ""
        }
    }