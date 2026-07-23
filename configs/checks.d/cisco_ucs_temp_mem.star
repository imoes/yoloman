def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.9.9.719.1.30.12.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        items = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_val = parts[0].strip()
            value = parts[1].strip()
            # Extract name from OID (e.g., .1.3.6.1.4.1.9.9.719.1.30.12.1.2.<item>.<something>)
            # We need to extract the 4th component of the OID path
            oid_parts = oid_val.split(".")
            if len(oid_parts) >= 7:
                item_name = oid_parts[6]  # The 4th component after base
                items.append({
                    "item": item_name,
                    "params": {"warn": 75.0, "crit": 85.0},
                    "metrics": ["temperature"]
                })
        return {"changed": False, "msg": "discovered %d memory temperature sensors" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Build OID for specific item: .1.3.6.1.4.1.9.9.719.1.30.12.1.2.<item>
    item_oid = ".1.3.6.1.4.1.9.9.719.1.30.12.1.2." + item
    
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On", host,
        item_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP get failed for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP response
    output = res.stdout.strip()
    # Expected format: OID = INTEGER: value
    if "=" not in output:
        return {"changed": False, "msg": "SNMP response parse error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts = output.split(" = ")
    if len(parts) < 2:
        return {"changed": False, "msg": "SNMP response parse error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract the value - typically in format "INTEGER: value" or just "value"
    value_part = parts[1].strip()
    if value_part.startswith("INTEGER:"):
        value_str = value_part.split(":", 1)[1].strip()
    else:
        value_str = value_part
    
    # Convert to integer
    if not value_str.isdigit():
        return {"changed": False, "msg": "Invalid temperature value: " + value_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp = int(value_str)
    warn = params.get("warn", 75.0)
    crit = params.get("crit", 85.0)
    
    # Determine state based on thresholds
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {"changed": False, "msg": "Temperature: %d C" % temp,
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}
