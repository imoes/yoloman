# Module-level constants
DEFAULT_WARN = 80
DEFAULT_CRIT = 90

# SNMP base OIDs for each variant
OID_BASE_TMS = ".1.3.6.1.4.1.9694.1.5.2"
OID_DISK_USAGE_TMS = OID_BASE_TMS + ".6.0"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Query disk usage via SNMP
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            OID_DISK_USAGE_TMS
        ], mutates=False)
        
        # Parse output: "oid = INTEGER: value" or "oid = INTEGER: value%"
        # We expect exactly one scalar result
        items = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Extract value after '=' and before any '%' or whitespace
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            value_part = parts[1].strip()
            # Extract numeric value
            numeric_str = ""
            for ch in value_part:
                if ch.isdigit():
                    numeric_str += ch
                else:
                    break
            if numeric_str.isdigit():
                usage = int(numeric_str)
                # Only discover if we got a valid value
                items.append({
                    "item": "/",
                    "params": {"levels": (DEFAULT_WARN, DEFAULT_CRIT)},
                    "metrics": ["disk_utilization"]
                })
                break
        
        return {
            "changed": False,
            "msg": "discovered %d filesystem(s)" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode (single item "/")
    item = params.get("item", "")
    if item != "/":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Query disk usage via SNMP
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        OID_DISK_USAGE_TMS
    ], mutates=False)
    
    # Parse output to extract numeric percentage value
    usage = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        numeric_str = ""
        for ch in value_part:
            if ch.isdigit():
                numeric_str += ch
            else:
                break
        if numeric_str.isdigit():
            usage = int(numeric_str)
            break
    
    # If no data, return UNKNOWN
    if usage == None:
        return {
            "changed": False,
            "msg": "No disk usage data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract thresholds from params
    levels = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))
    warn = levels[0]
    crit = levels[1]
    
    # Determine state based on thresholds (upper levels)
    state = "OK"
    if usage >= crit:
        state = "CRIT"
    elif usage >= warn:
        state = "WARN"
    
    # Build message (Checkmk-style)
    msg = "Disk usage %d%%" % usage
    
    # Return metrics in normalized form (0.0-1.0)
    disk_utilization = float(usage) / 100.0
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"disk_utilization": disk_utilization},
            "details": ""
        }
    }
