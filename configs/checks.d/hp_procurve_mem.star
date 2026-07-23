# SNMP OIDs for HP ProCurve memory
OID_TOTAL = ".1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.5"
OID_ALLOC = ".1.3.6.1.4.1.11.2.14.11.5.1.1.2.1.1.1.7"

def _parse_snmp_value(output):
    """Parse SNMP output line 'OID = TYPE: value' to extract numeric value"""
    if output == None or len(output) == 0:
        return None
    # Split on last space to get "TYPE: value" part
    parts = output.rsplit(" ", 1)
    if len(parts) < 2:
        return None
    value_part = parts[1].strip()
    # Extract value after colon if present
    if ":" in value_part:
        value_part = value_part.split(":", 1)[1].strip()
    # Handle negative numbers
    if len(value_part) == 0:
        return None
    is_negative = False
    if value_part.startswith("-"):
        is_negative = True
        value_part = value_part[1:]
    # Check if it's a valid integer string
    for c in value_part:
        if c < "0" or c > "9":
            return None
    # Convert to integer
    result = 0
    for c in value_part:
        result = result * 10 + (ord(c) - ord("0"))
    if is_negative:
        result = -result
    return result

def _snmp_get_value(ctx, host, community, oid):
    """Get a single SNMP value via snmpget"""
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, oid
    ], mutates=False)
    if res.rc != 0:
        return None
    return _parse_snmp_value(res.stdout.strip())

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: always discover a single service for memory
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {"levels": ("perc_used", (80.0, 90.0))}, "metrics": ["mem_used"]}
            ]}
        }
    
    # Check mode: single service with item ""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Get memory values via SNMP
    mem_total = _snmp_get_value(ctx, host, community, OID_TOTAL)
    mem_used = _snmp_get_value(ctx, host, community, OID_ALLOC)
    
    # Check if we got valid data
    if mem_total == None or mem_used == None:
        return {
            "changed": False,
            "msg": "unable to retrieve memory information via SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get levels from params (Checkmk default: ("perc_used", (80.0, 90.0)))
    levels = params.get("levels", ("perc_used", (80.0, 90.0)))
    
    # Calculate usage percentage
    if mem_total <= 0:
        return {
            "changed": False,
            "msg": "total memory is zero or negative",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    usage_percent = (mem_used / mem_total) * 100.0
    
    # Extract warn/crit thresholds
    warn, crit = 80.0, 90.0
    if type(levels) == "tuple" and len(levels) == 2:
        if type(levels[0]) == "string" and levels[0] == "perc_used":
            threshold_tuple = levels[1]
            if type(threshold_tuple) == "tuple" and len(threshold_tuple) == 2:
                warn = float(threshold_tuple[0])
                crit = float(threshold_tuple[1])
        elif type(levels[0]) == "float" or type(levels[0]) == "int":
            # Legacy format (warn, crit)
            warn = float(levels[0])
            crit = float(levels[1])
    
    # Determine state based on thresholds
    if usage_percent >= crit:
        state = "CRIT"
    elif usage_percent >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Format message
    msg = "Usage: %f%%" % usage_percent
    
    # Return check result
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"mem_used": mem_used, "mem_used_percent": usage_percent},
            "details": ""
        }
    }