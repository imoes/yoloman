def main(ctx, params):
    # Discovery mode: emit one item for the root filesystem
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "/", "params": {"levels": (80.0, 90.0)}, "metrics": ["disk_utilization"]}
                ]
            },
        }

    # Check mode: fetch SNMP data and compute verdict
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    oid = ".1.3.6.1.4.1.9694.1.4.2.1.4.0"

    # Use snmpwalk (single scalar OID) - return value is "OID = INTEGER: value"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, oid],
        mutates=False
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    if len(lines) == 0 or lines[0].strip() == "":
        return {
            "changed": False,
            "msg": "empty SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse line: ".1.3.6.1.4.1.9694.1.4.2.1.4.0 = INTEGER: 42"
    line = lines[0].strip()
    # Extract value after the last ": "
    idx = line.rfind(": ")
    if idx == -1:
        return {
            "changed": False,
            "msg": "cannot parse SNMP value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    raw_val = line[idx + 2:].strip()

    # Guard before parsing — ensure string is numeric
    if not raw_val.replace("-", "").isdigit() or not raw_val:
        return {
            "changed": False,
            "msg": "invalid SNMP value: " + raw_val,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    usage_percent = int(raw_val)

    # Get thresholds from params using Checkmk defaults
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if isinstance(levels, list) and len(levels) >= 1 else 80.0
    crit = levels[1] if isinstance(levels, list) and len(levels) >= 2 else 90.0

    # Determine state based on upper levels
    state = "CRIT" if usage_percent >= crit else ("WARN" if usage_percent >= warn else "OK")

    # Build message
    msg = "Disk usage %d%%" % usage_percent

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"disk_utilization": float(usage_percent) / 100.0},
            "details": ""
        }
    }
