def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.12527.29"], mutates=False)
        # If first tree fails, try second tree
        if res.rc != 0 or res.stdout == "":
            res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.12527.40"], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "ntpSysStratum", "params": {}, "metrics": []}]}}
    
    # Check mode: item is always "ntpSysStratum"
    # We need to fetch the NTP stratum value via SNMP
    # The OID for ntpStratum is .1.3.6.1.4.1.12527.29.2.1.2.0 or .1.3.6.1.4.1.12527.40.2.1.2.0
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.12527.29.2.1.2.0"], mutates=False)
    if res.rc != 0 or res.stdout == "":
        res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.12527.40.2.1.2.0"], mutates=False)
    
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "unable to retrieve ntpSysStratum data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the SNMP output: expected format is "OID = INTEGER: <value>"
    line = res.stdout.strip()
    value = ""
    if "=" in line:
        parts = line.split("=", 1)
        if len(parts) == 2:
            val_part = parts[1].strip()
            # Extract the integer value (e.g., "INTEGER: 1" or just "1")
            if val_part.startswith("INTEGER:"):
                value = val_part.split(":", 1)[1].strip()
            elif val_part.isdigit():
                value = val_part
    
    # Default state if value not found
    if value == "":
        return {"changed": False, "msg": "ntpSysStratum data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply the check logic per original
    if value == "1":
        state = "OK"
        summary = "Stratum 1, Primary Reference"
    elif value == "16":
        state = "CRIT"
        summary = "Stratum Invalid"
    elif value == "0":
        state = "UNKNOWN"
        summary = "Stratum Unknown"
    else:
        state = "WARN"
        summary = "Stratum is using secondary reference(via NTP)"
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}
