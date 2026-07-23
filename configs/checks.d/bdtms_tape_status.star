# Map health_id to status text
HEALTH_MAP = {
    "1": "unknown",
    "2": "ok",
    "3": "warning",
    "4": "critical",
}

# Map status text to Checkmk state
STATUS_MAP = {
    "unknown": "UNKNOWN",
    "ok": "OK",
    "warning": "WARN",
    "critical": "CRIT",
}

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]
            },
        }

    # Read SNMP data via snmpwalk
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Base OID from Checkmk source: .1.3.6.1.4.1.20884.2
    base_oid = ".1.3.6.1.4.1.20884.2"
    # Checkmk fetches oids=["1", "3"] -> full OIDs: .1.3.6.1.4.1.20884.2.1 and .1.3.6.1.4.1.20884.2.3
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1", base_oid + ".3"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP query failed"
            }
        }

    # Parse snmpwalk output: lines like "OID = STRING: value" or "OID = INTEGER: value"
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {
            "changed": False,
            "msg": "missing SNMP data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Expected 2 OIDs but got less"
            }
        }

    # Extract values from lines
    # Activity ID: .1.3.6.1.4.1.20884.2.1 (first OID)
    # Health ID: .1.3.6.1.4.1.20884.2.3 (second OID)
    values = []
    for line in lines:
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        # Extract value after type indicator (INTEGER:, STRING:, etc.)
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip()
            values.append(value)
        else:
            values.append(value_part)

    if len(values) < 2:
        return {
            "changed": False,
            "msg": "incomplete SNMP data",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Expected 2 values but got " + str(len(values))
            }
        }

    activity_id, health_id = values[0], values[1]

    # Map health_id to status text
    health = HEALTH_MAP.get(health_id, "unknown")
    state = STATUS_MAP.get(health, "UNKNOWN")

    return {
        "changed": False,
        "msg": health,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
