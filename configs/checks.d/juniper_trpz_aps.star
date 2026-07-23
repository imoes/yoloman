def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["ap_devices_total", "total_sessions"]}]},
        }

    # Single-host check path
    # Probe: SNMP walk on .1.3.6.1.4.1.14525.4.5.1.1.1 and .1.3.6.1.4.1.14525.4.4.1.4
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.14525.4.5.1.1.1",
        ".1.3.6.1.4.1.14525.4.4.1.4"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = res.stdout.splitlines()
    active_aps = 0
    sessions = 0
    found_aps = False
    found_sessions = False

    for line in lines:
        stripped = line.strip()
        # ap devices: .1.3.6.1.4.1.14525.4.5.1.1.1.0 = INTEGER: 1
        if stripped.startswith(".1.3.6.1.4.1.14525.4.5.1.1.1"):
            idx = stripped.find(":")
            if idx != -1:
                val = stripped[idx+1:].strip()
                if val.isdigit():
                    active_aps = int(val)
                    found_aps = True
        # sessions: .1.3.6.1.4.1.14525.4.4.1.4.0 = INTEGER: 0
        if stripped.startswith(".1.3.6.1.4.1.14525.4.4.1.4"):
            idx = stripped.find(":")
            if idx != -1:
                val = stripped[idx+1:].strip()
                if val.isdigit():
                    sessions = int(val)
                    found_sessions = True

    if not found_aps or not found_sessions:
        return {
            "changed": False,
            "msg": "expected SNMP OIDs not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK"
    return {
        "changed": False,
        "msg": "Online access points: %d, Sessions: %d" % (active_aps, sessions),
        "data": {
            "state": state,
            "metrics": {"ap_devices_total": active_aps, "total_sessions": sessions},
            "details": "",
        },
    }
