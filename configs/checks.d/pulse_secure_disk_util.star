def main(ctx, params):
    # Read-only probe: fetch disk utilization via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.12532.25"
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "SNMP query failed or returned no data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output: "OID = INTEGER: value"
    # Look for the single value under .1.3.6.1.4.1.12532.25
    value = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(".1.3.6.1.4.1.12532.25"):
            parts = stripped.split(" = ")
            if len(parts) == 2:
                # Extract value after "INTEGER: " or just the numeric part
                val_part = parts[1].strip()
                if val_part.startswith("INTEGER: "):
                    numeric_str = val_part.split("INTEGER: ", 1)[1].strip()
                    if numeric_str.isdigit() or (numeric_str.startswith("-") and numeric_str[1:].isdigit()):
                        value = int(numeric_str)
                else:
                    if val_part.isdigit() or (val_part.startswith("-") and val_part[1:].isdigit()):
                        value = int(val_part)

    if value == None:
        return {
            "changed": False,
            "msg": "Could not parse disk utilization value from SNMP output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Thresholds: Checkmk defaults (80.0, 90.0) via upper_levels
    upper_levels = params.get("upper_levels", (80.0, 90.0))
    warn = upper_levels[0] if len(upper_levels) >= 1 else 80.0
    crit = upper_levels[1] if len(upper_levels) >= 2 else 90.0

    # Determine state
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Build message and metrics
    msg = "Percentage of disk space used: %d%%" % value
    metrics = {"disk_utilization": value}

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        },
    }