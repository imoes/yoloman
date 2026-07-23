def main(ctx, params):
    # SNMP parameters
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Checkmk defaults for levels
    warn = params.get("levels", (80, 90))[0]
    crit = params.get("levels", (80, 90))[1]
    
    # Discovery mode: always yield exactly one service if SNMP data exists
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        ], mutates=False)
        
        # Check if any line contains "Reheat"
        has_reheat = False
        for line in res.stdout.splitlines():
            if "Reheat" in line:
                has_reheat = True
                break
        
        if has_reheat:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {"levels": (80, 90)},
                            "metrics": ["fan_perc"]
                        }
                    ]
                }
            }
        else:
            return {
                "changed": False,
                "msg": "no reheating data found",
                "data": {"discovery": []}
            }
    
    # Check mode: fetch the three OIDs for reheating utilization
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    ], mutates=False)
    
    lines = res.stdout.splitlines()
    
    # Parse SNMP lines in groups of three: name, value, unit
    i = 0
    found = False
    value = None
    unit = ""
    
    while i < len(lines):
        # Look for name line containing "Reheat"
        if "Reheat" in lines[i]:
            if i + 2 < len(lines):
                # Extract OID and value from line format: "oid = TYPE: value"
                # Line 1: name
                name_line = lines[i]
                name_parts = name_line.split(" = ")
                if len(name_parts) >= 2:
                    # Line 2: value
                    value_line = lines[i + 1]
                    value_parts = value_line.split(" = ")
                    if len(value_parts) >= 2:
                        value_str = value_parts[1].strip()
                        # Handle format like "INTEGER: 0" or just "0"
                        if ":" in value_str:
                            value_str = value_str.split(":")[1].strip()
                        # Line 3: unit
                        unit_line = lines[i + 2]
                        unit_parts = unit_line.split(" = ")
                        if len(unit_parts) >= 2:
                            unit_str = unit_parts[1].strip()
                            if ":" in unit_str:
                                unit_str = unit_str.split(":")[1].strip()
                            
                            # Guard instead of try/except: check numeric format first
                            value_ok = False
                            vs = value_str
                            # Handle negative numbers and decimals
                            if vs != "" and vs != "-":
                                vs_clean = vs.replace("-", "", 1).replace(".", "", 1)
                                if vs_clean.isdigit():
                                    value_ok = True
                            
                            if value_ok:
                                value = float(value_str)
                                unit = unit_str
                                found = True
                break
        i = i + 1
    
    if not found or value == None:
        return {
            "changed": False,
            "msg": "no reheating utilization data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Apply levels
    state = "OK"
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    
    msg = "%s%f %s" % (state + " " if state != "OK" else "", value, unit)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"fan_perc": value},
            "details": ""
        }
    }