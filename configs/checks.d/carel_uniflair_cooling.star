def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    base_oid = ".1.3.6.1.4.1.9839.2.1"
    oids = ["1.31.0", "1.51.0", "1.67.0", "2.6.0"]
    
    if params.get("_discover"):
        # Single-service check: always discover one item with empty name
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["humidity"]
                    }
                ]
            }
        }
    
    # Check mode - fetch all required OIDs
    items = []
    for i in range(len(oids)):
        full_oid = base_oid + "." + oids[i]
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, full_oid], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP error for OID " + full_oid + ": " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        # Parse "OID = TYPE: value" format
        line = res.stdout.strip()
        # Extract value after ": "
        idx = line.find(": ")
        if idx == -1:
            return {
                "changed": False,
                "msg": "unexpected SNMP output format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        value_part = (line[idx + 2:]).strip()
        items.append(value_part)
    
    if len(items) != 4:
        return {
            "changed": False,
            "msg": "expected 4 OID values, got %d" % len(items),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    waterloss, global_status, emergency_op, r_humidity = items
    
    # Validate values before conversion - use isdigit() for non-negative integers
    waterloss_int = int(waterloss) if waterloss.isdigit() or (waterloss.startswith("-") and waterloss[1:].isdigit()) else -1
    global_status_int = int(global_status) if global_status.isdigit() else -1
    emergency_op_int = int(emergency_op) if emergency_op.isdigit() else -1
    
    # Convert humidity safely
    humidity_val = 0.0
    if r_humidity == "" or r_humidity == None:
        humidity_val = -1.0
    else:
        # Check if string represents a valid float
        dot_count = r_humidity.count(".")
        valid = dot_count <= 1
        if valid:
            parts = r_humidity.split(".")
            for part in parts:
                if part != "" and not part.isdigit():
                    valid = False
                    break
            if valid:
                humidity_val = float(r_humidity) / 10.0
    
    # Check if conversion failed
    if waterloss_int == -1 or global_status_int == -1 or emergency_op_int == -1 or humidity_val == -1.0:
        return {
            "changed": False,
            "msg": "failed to parse SNMP values",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Evaluate status
    err_waterloss = waterloss_int != 0
    err_global_status = global_status_int != 1
    err_emergency_op = emergency_op_int != 0
    
    # Build output string
    output = ""
    output = output + "Global Status: %s, " % ("Error(!!), " if err_global_status else "OK, ")
    output = output + "Emergency Operation: %s, " % ("Active(!!), " if err_emergency_op else "Inactive, ")
    output = output + "Humidifier: %s, " % ("Water Loss(!!), " if err_waterloss else "No Water Loss, ")
    output = output + "Humidity: %f%%" % humidity_val
    
    # Determine state
    state = "CRIT" if err_waterloss or err_global_status or err_emergency_op else "OK"
    
    return {
        "changed": False,
        "msg": output,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity_val},
            "details": ""
        }
    }
