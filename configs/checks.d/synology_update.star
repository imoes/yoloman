# Synology update check (read-only, SNMP-based)

def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Gather SNMP data for synology_update
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.6574.1.5"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse OID output: ".1.3.6.1.4.1.6574.1.5.3 = STRING: \"DSM 7\""
    # and ".1.3.6.1.4.1.6574.1.5.4 = INTEGER: 2"
    version = ""
    status_str = ""
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0]
        value_part = parts[1]

        if oid_part.endswith(".3"):
            # Extract string value between quotes
            if value_part.startswith("STRING:"):
                version = value_part[7:].strip().strip('"')
        elif oid_part.endswith(".4"):
            if value_part.startswith("INTEGER:"):
                status_str = value_part[8:].strip()

    # Check status_str validity before converting to int
    status = None
    if status_str != "":
        if status_str.lstrip("-").isdigit():
            status = int(status_str)

    # No valid data
    if status == None or version == "":
        return {
            "changed": False,
            "msg": "no update data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract thresholds from params with Checkmk defaults
    ok_states = params.get("ok_states", [2])
    warn_states = params.get("warn_states", [5])
    crit_states = params.get("crit_states", [1, 4])

    # Map status codes to states
    STATE_NAMES = {
        1: "Available",
        2: "Unavailable",
        3: "Connecting",
        4: "Disconnected",
        5: "Others"
    }

    state_name = STATE_NAMES.get(status, "Unknown")

    # Special case: status 3 -> UNKNOWN with IgnoreResultsError equivalent
    if status == 3:
        return {
            "changed": False,
            "msg": "Device tries to connect to the update server",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Determine Checkmk state
    if status in ok_states:
        state = "OK"
    elif status in warn_states:
        state = "WARN"
    elif status in crit_states:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    return {
        "changed": False,
        "msg": "Update Status: " + state_name + ", Current Version: " + version,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }