# Map status IDs to textual descriptions and their Checkmk states
STATUS_MAP = {
    "1": "other",
    "2": "unknown",
    "3": "ok",
    "4": "non-critical",
    "5": "critical",
    "6": "non-recoverable",
}

STATE_MAP = {
    "other": "UNKNOWN",
    "unknown": "UNKNOWN",
    "ok": "OK",
    "non-critical": "WARN",
    "critical": "CRIT",
    "non-recoverable": "CRIT",
}


def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    },
                ],
            },
        }

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.20884.10893.2.101.2.1",
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Parse SNMP output line: OID = STRING: value
    status_id = ""
    for line in res.stdout.splitlines():
        line = line.strip()
        # Format: .1.3.6.1.4.1.20884.10893.2.101.2.1.0 = STRING: "1"
        if not line.startswith(".1.3.6.1.4.1.20884.10893.2.101.2.1.1"):
            continue
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        value_part = parts[1].strip()
        # Extract value after type prefix (e.g., 'STRING: "1"' -> "1")
        if value_part.startswith("STRING:"):
            status_id = value_part[7:].strip().strip('"')
            break
    
    if not status_id:
        return {
            "changed": False,
            "msg": "no status value found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    status = STATUS_MAP.get(status_id, "unknown")
    state = STATE_MAP.get(status, "UNKNOWN")

    return {
        "changed": False,
        "msg": status,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
