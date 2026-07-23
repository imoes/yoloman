def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.4547.2.3.2.4"
        ], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }

        # Only check the chassis section (single-service check)
        # The check only produces one service for the whole chassis
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode (non-discovery)
    # Fetch all required OIDs: 4=minOperTemp, 5=maxOperTemp, 8=chassisTemp, 11=throughputStatus
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.4547.2.3.2"
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "Unable to retrieve SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output into a dict keyed by OID suffix (e.g., "4", "5", etc.)
    values = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, val_part = parts
        # Extract suffix: e.g., ".1.3.6.1.4.1.4547.2.3.2.4" -> "4"
        suffix = oid_full.rsplit(".", 1)[-1]
        # Extract value: e.g., "Integer: 25" -> "25"
        val_str = val_part.split(": ", 1)[-1].strip()
        if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
            values[suffix] = int(val_str)
        else:
            values[suffix] = val_str

    # Extract required values with defaults
    throughput_status = values.get("11", "")
    min_oper_temp = values.get("4", 0)
    max_oper_temp = values.get("5", 0)
    chassis_temp = values.get("8", 0)

    # Determine state based on throughput status
    state = "OK"
    msg_parts = []
    
    # Throughput status check
    if throughput_status == "1":
        msg_parts.append("Normal")
    elif throughput_status == "2":
        state = "WARN"
        msg_parts.append("Warning")
    else:
        state = "UNKNOWN"
        msg_parts.append("Unknown throughput status (" + str(throughput_status) + ")")

    # Temperature check if available
    if chassis_temp != 0 or min_oper_temp != 0 or max_oper_temp != 0:
        temp_warn = max_oper_temp
        temp_crit = max_oper_temp
        temp_warn_lower = min_oper_temp
        temp_crit_lower = min_oper_temp
        
        # Upper thresholds
        if chassis_temp >= temp_crit:
            state = "CRIT"
            msg_parts.insert(0, "Temperature CRIT (>= %dC)" % temp_crit)
        elif chassis_temp >= temp_warn:
            state = "WARN"
            msg_parts.insert(0, "Temperature WARN (>= %dC)" % temp_warn)
        
        # Lower thresholds (only if they make sense and we have valid data)
        if chassis_temp != 0 and temp_warn_lower != 0:
            if chassis_temp <= temp_crit_lower:
                state = "CRIT"
                msg_parts.insert(0, "Temperature CRIT (<= %dC)" % temp_crit_lower)
            elif chassis_temp <= temp_warn_lower:
                state = "WARN"
                msg_parts.insert(0, "Temperature WARN (<= %dC)" % temp_warn_lower)

        # Add temperature reading to message
        msg_parts.append("Temp: %dC" % chassis_temp)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"throughput_status": 1 if throughput_status == "1" else (2 if throughput_status == "2" else -1)},
            "details": ""
        }
    }
