# Module-level constants
SNMP_BASE_OID = ".1.3.6.1.4.1.334.72.1.1.6.3"
SNMP_OID_USERS = "6"
DEFAULT_LEVELS = (1000, 1500)

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [
                {"item": "", "params": {"levels": DEFAULT_LEVELS}, "metrics": ["users"]}
            ]},
        }

    # Check mode
    item = params.get("item", "")
    levels = params.get("levels", DEFAULT_LEVELS)
    warn, crit = levels[0], levels[1]

    # SNMP probe (read-only, no mutates)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        SNMP_BASE_OID + "." + SNMP_OID_USERS
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output: expected format "OID = INTEGER: <value>"
    users = None
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        # Split on '=' and extract value
        parts = line.strip().split("=", 1)
        if len(parts) == 2:
            value_part = parts[1].strip()
            # Extract numeric value (INTEGER: value or Gauge32: value etc.)
            if value_part.startswith("INTEGER:"):
                value_str = value_part.split(":", 1)[1].strip()
                users = int(value_str) if value_str.isdigit() else None
                if users != None:
                    break
            elif value_part.startswith("Gauge32:"):
                value_str = value_part.split(":", 1)[1].strip()
                users = int(value_str) if value_str.isdigit() else None
                if users != None:
                    break

    if users == None:
        return {
            "changed": False,
            "msg": "no users count found in SNMP output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine state based on levels
    if users >= crit:
        state = "CRIT"
    elif users >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Domino users on server: %d" % users,
        "data": {
            "state": state,
            "metrics": {"users": users},
            "details": ""
        },
    }
