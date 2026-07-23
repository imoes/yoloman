# Module-level constants
SNMP_BASE_OID = ".1.3.6.1.4.1.12356.105.1"
SNMP_OID_DISK_USAGE = "9"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [
                {"item": "", "params": {"disk_usage": (80.0, 90.0)}, "metrics": ["disk_utilization"]}
            ]},
        }
    
    # Check mode - single service with empty item
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Run snmpget for the specific OID
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On",
        host,
        SNMP_BASE_OID + "." + SNMP_OID_DISK_USAGE
    ], mutates=False)
    
    # Parse SNMP response
    # Expected format: "<OID> = INTEGER: <value>"
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    line = res.stdout.strip()
    if "INTEGER:" not in line and "Gauge32:" not in line:
        return {
            "changed": False,
            "msg": "Unexpected SNMP response format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract value after "INTEGER:" or "Gauge32:"
    parts = line.split(":")
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "Failed to parse SNMP value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value_str = parts[-1].strip()
    cleaned = value_str.strip("L")  # Some SNMP implementations may append 'L'
    
    # Guard before risky conversion: check if string looks numeric
    is_numeric = True
    # Remove leading/trailing whitespace and check for valid numeric chars
    cleaned = cleaned.strip()
    # Handle potential negative sign, decimal point, and digits only
    allowed_chars = "0123456789.+-"
    if cleaned:
        for c in cleaned:
            if c not in allowed_chars:
                is_numeric = False
                break
    
    if not is_numeric or not cleaned:
        return {
            "changed": False,
            "msg": "Invalid disk usage value: " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    disk_usage = float(cleaned)
    
    # Get thresholds from params
    levels = params.get("disk_usage", (80.0, 90.0))
    warn = levels[0]
    crit = levels[1]
    
    # Determine state based on thresholds
    # Upper levels: WARN if value >= warn, CRIT if value >= crit
    if disk_usage >= crit:
        state = "CRIT"
    elif disk_usage >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message in Checkmk style
    msg = "Disk usage: %f%%" % disk_usage
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"disk_utilization": disk_usage},
            "details": ""
        },
    }
