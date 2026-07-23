def main(ctx, params):
    # Discovery mode: return one service with default params
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "monitoring_status_memory_available": 0,  # State.OK
                            "monitoring_status_memory_shortage": 1,  # State.WARN
                            "monitoring_status_memory_full": 2,      # State.CRIT
                        },
                        "metrics": [],
                    }
                ]
            },
        }

    # Check mode: get SNMP data and evaluate state
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = ".1.3.6.1.4.1.15497.1.1.1.7"

    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-On", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Parse "OID = STRING: <value>" or "OID = INTEGER: <value>"
    line = res.stdout.strip()
    # Split on '=' and get the value part
    parts = line.split("=", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid SNMP response format",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    value_part = parts[1].strip()
    # Extract numeric value from "INTEGER: <n>" or "INTEGER: <n>" or similar
    # Checkmk uses integer parsing, so we try to extract the number
    # Common formats: "INTEGER: 1", "INTEGER: 2", "INTEGER: 3"
    if not value_part.startswith("INTEGER: "):
        return {
            "changed": False,
            "msg": "unexpected SNMP value format: " + value_part,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    status_str = value_part.split("INTEGER: ", 1)[1].strip()
    if not status_str.isdigit():
        return {
            "changed": False,
            "msg": "non-numeric status value: " + status_str,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    status = int(status_str)

    # Map to Checkmk states
    status_map = {
        1: "memory_available",
        2: "memory_shortage",
        3: "memory_full",
    }

    state_name = status_map.get(status)
    if state_name == None:
        return {
            "changed": False,
            "msg": "unknown status value: " + str(status),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Get thresholds from params with Checkmk defaults
    warn = params.get("monitoring_status_memory_shortage", 1)  # State.WARN
    crit = params.get("monitoring_status_memory_full", 2)      # State.CRIT
    ok = params.get("monitoring_status_memory_available", 0)   # State.OK

    # Determine state
    state = "OK"
    if status == 2:  # memory_shortage
        state = "WARN" if warn == 1 else ("CRIT" if warn == 2 else "OK")
    elif status == 3:  # memory_full
        state = "CRIT" if crit == 2 else ("WARN" if crit == 1 else "OK")

    # Summary message
    summary = "Memory " + state_name.replace("_", " ")

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
