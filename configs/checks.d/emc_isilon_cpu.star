# Module-level constant for SNMP base OID
EMC_ISILON_CPU_OID_BASE = ".1.3.6.1.4.1.12124.2.2.3"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Single-service check - one entry with empty item
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": ["user", "system", "interrupt", "Total"]}
                ]
            },
        }

    # Check mode
    # Get SNMP data for CPU utilization
    # OIDs: 1=user, 2=nice, 3=system, 4=interrupt
    oids = ["1", "2", "3", "4"]
    
    # Fetch each OID individually (more reliable than snmpwalk for specific OIDs)
    results = []
    for oid in oids:
        full_oid = EMC_ISILON_CPU_OID_BASE + "." + oid
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), 
                      "-On", params.get("host", "localhost"), full_oid], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        results.append(res.stdout.strip())
    
    if len(results) != 4:
        return {
            "changed": False,
            "msg": "Expected 4 SNMP values, got " + str(len(results)),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output - format is: OID = TYPE: value
    values = []
    for result in results:
        # Check if result contains " = " separator
        if " = " not in result:
            return {
                "changed": False,
                "msg": "Invalid SNMP output format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        # Extract value after " = "
        value_part = result.split(" = ", 1)[1]
        
        # Extract numeric value
        num_str = ""
        if " : " in value_part:
            # Handle TYPE: value format
            num_str = value_part.split(" : ", 1)[1].strip()
        elif ": " in value_part:
            # Handle TYPE: value format (alternative spacing)
            num_str = value_part.split(": ", 1)[1].strip()
        else:
            num_str = value_part.strip()
        
        # Clean up numeric string
        if " " in num_str:
            num_str = num_str.split(" ")[0]
        
        # Validate it's a digit string before converting
        if not num_str.replace("-", "").isdigit():
            return {
                "changed": False,
                "msg": "Failed to parse SNMP value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        
        values.append(int(num_str))

    if len(values) != 4:
        return {
            "changed": False,
            "msg": "Expected 4 values, got " + str(len(values)),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse values: [user, nice, system, interrupt]
    user_val = values[0]
    nice_val = values[1]
    system_val = values[2]
    interrupt_val = values[3]

    # Calculate percentages (per mil to percent: * 0.1)
    user_perc = (user_val + nice_val) * 0.1
    system_perc = system_val * 0.1
    interrupt_perc = interrupt_val * 0.1
    total_perc = user_perc + system_perc + interrupt_perc

    # Get thresholds from params (Checkmk default: no levels, so always OK unless levels specified)
    warn = None
    crit = None
    levels = params.get("util", None)
    if levels != None and type(levels) == "list" and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]

    # Determine state for total utilization
    state = "OK"
    if crit != None and total_perc >= crit:
        state = "CRIT"
    elif warn != None and total_perc >= warn:
        state = "WARN"

    # Build metrics
    metrics = {
        "user": user_perc,
        "system": system_perc,
        "interrupt": interrupt_perc,
        "Total": total_perc
    }

    # Build message
    msg = "Total: %f%%, User: %f%%, System: %f%%, Interrupt: %f%%" % (
        total_perc, user_perc, system_perc, interrupt_perc
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
