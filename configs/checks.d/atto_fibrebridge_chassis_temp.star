def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.4.1.4547.2.3.2.4", ".1.3.6.1.4.1.4547.2.3.2.5",
            ".1.3.6.1.4.1.4547.2.3.2.8", ".1.3.6.1.4.1.4547.2.3.2.11"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP probe failed", "data": {"discovery": []}}
        
        # Parse output: collect all OIDs and values
        lines = res.stdout.splitlines()
        oid_values = {}
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                oid_part = parts[0].strip()
                val_part = parts[1].strip()
                # Extract value (handle INTEGER: and STRING: prefixes)
                if val_part.startswith("INTEGER:"):
                    val = int(val_part.split(":", 1)[1].strip())
                elif val_part.startswith("STRING:"):
                    val = val_part.split(":", 1)[1].strip().strip('"')
                else:
                    continue
                oid_values[oid_part] = val
        
        # Check if all needed OIDs are present (detect detection)
        if ".1.3.6.1.4.1.4547.2.3.2.4" in oid_values and \
           ".1.3.6.1.4.1.4547.2.3.2.5" in oid_values and \
           ".1.3.6.1.4.1.4547.2.3.2.8" in oid_values and \
           ".1.3.6.1.4.1.4547.2.3.2.11" in oid_values:
            return {
                "changed": False,
                "msg": "discovered 1 item",
                "data": {
                    "discovery": [
                        {"item": "Chassis", "params": {}, "metrics": ["temperature"]}
                    ]
                },
            }
        return {"changed": False, "msg": "no chassis detected", "data": {"discovery": []}}

    # Check mode
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.4547.2.3.2.4", ".1.3.6.1.4.1.4547.2.3.2.5",
        ".1.3.6.1.4.1.4547.2.3.2.8", ".1.3.6.1.4.1.4547.2.3.2.11"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP probe failed", "data": {
            "state": "UNKNOWN", "metrics": {}, "details": ""
        }}

    # Parse SNMP output
    lines = res.stdout.splitlines()
    oid_values = {}
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) == 2:
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            if val_part.startswith("INTEGER:"):
                val = int(val_part.split(":", 1)[1].strip())
            elif val_part.startswith("STRING:"):
                val = val_part.split(":", 1)[1].strip().strip('"')
            else:
                continue
            oid_values[oid_part] = val

    # Detection check: required OIDs must be present
    required_oids = [".1.3.6.1.4.1.4547.2.3.2.4", ".1.3.6.1.4.1.4547.2.3.2.5", 
                     ".1.3.6.1.4.1.4547.2.3.2.8", ".1.3.6.1.4.1.4547.2.3.2.11"]
    for oid in required_oids:
        if oid not in oid_values:
            return {"changed": False, "msg": "missing SNMP data", "data": {
                "state": "UNKNOWN", "metrics": {}, "details": ""
            }}

    min_operating_temp = int(oid_values[".1.3.6.1.4.1.4547.2.3.2.4"])
    max_operating_temp = int(oid_values[".1.3.6.1.4.1.4547.2.3.2.5"])
    chassis_temp = int(oid_values[".1.3.6.1.4.1.4547.2.3.2.8"])

    # Build temperature parameters (use default Checkmk thresholds from the plugin)
    warn_upper = max_operating_temp
    crit_upper = max_operating_temp
    warn_lower = min_operating_temp
    crit_lower = min_operating_temp

    # Determine state
    state = "OK"
    if chassis_temp >= crit_upper:
        state = "CRIT"
    elif chassis_temp >= warn_upper:
        state = "WARN"
    elif chassis_temp <= crit_lower:
        state = "CRIT"
    elif chassis_temp <= warn_lower:
        state = "WARN"

    msg = "Temperature: %d C" % chassis_temp

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": chassis_temp},
            "details": ""
        },
    }
