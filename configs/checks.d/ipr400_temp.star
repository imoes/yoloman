def main(ctx, params):
    # Discover mode
    if params.get("_discover"):
        # Single-service check: one item "Ambient"
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "Ambient",
                        "params": {"levels": (30.0, 40.0)},
                        "metrics": ["temperature"]
                    }
                ]
            }
        }

    # Check mode
    item = params.get("item", "")
    if item != "Ambient":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # SNMP data collection (same OID as Checkmk plugin)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get ambient temperature from OID .1.3.6.1.4.1.27053.1.4.5.9
    base_oid = ".1.3.6.1.4.1.27053.1.4.5.9"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid
    ], mutates=False)

    lines = res.stdout.splitlines() if res.stdout else []
    temp_value = None

    for line in lines:
        # Format: OID = INTEGER: value
        if line.strip().startswith(base_oid):
            parts = line.split("=")
            if len(parts) >= 2:
                value_part = parts[1].strip()
                # Extract numeric part after "INTEGER: " or just the number
                if value_part.startswith("INTEGER: "):
                    value_str = value_part[len("INTEGER: "):].strip()
                else:
                    value_str = value_part.strip()
                if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
                    temp_value = int(value_str)
                    break

    if temp_value == None:
        return {
            "changed": False,
            "msg": "temperature data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse params for thresholds
    levels = params.get("levels", (30.0, 40.0))
    warn = levels[0]
    crit = levels[1]

    # Determine state (Checkmk uses upper levels: WARN if >= warn, CRIT if >= crit)
    if temp_value >= crit:
        state = "CRIT"
    elif temp_value >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "Ambient temperature: %f C" % float(temp_value)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temperature": float(temp_value)},
            "details": ""
        }
    }