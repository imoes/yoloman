# Module-level constants
DISK_USAGE_OID = ".1.3.6.1.4.1.9694.1.6.2.6.0"

# Default levels (from FILESYSTEM_DEFAULT_PARAMS in Checkmk)
DEFAULT_WARN = 80.0
DEFAULT_CRIT = 90.0

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "/", "params": {"levels": (DEFAULT_WARN, DEFAULT_CRIT)}, "metrics": ["disk_utilization"]}
                ]
            }
        }

    # Check mode - single item "/"
    item = params.get("item", "")
    if item != "/":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Gather data via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-On", host, DISK_USAGE_OID],
        mutates=False
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output: ".1.3.6.1.4.1.9694.1.6.2.6.0 = INTEGER: 42"
    line = res.stdout.strip()
    if "=" not in line:
        return {
            "changed": False,
            "msg": "unexpected SNMP output format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_part = line.split("=", 1)[1].strip()
    if not value_part.startswith("INTEGER:"):
        return {
            "changed": False,
            "msg": "unexpected value format: expected INTEGER",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Guard before parsing: validate string format before converting
    number_str = value_part.split(":", 1)[1].strip()
    usage_percent = int(number_str) if number_str.isdigit() else 0

    # Apply thresholds (from params["levels"] if present, else defaults)
    levels = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))
    warn, crit = levels[0], levels[1]

    # Determine state
    if usage_percent >= crit:
        state = "CRIT"
    elif usage_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    # Format message
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
