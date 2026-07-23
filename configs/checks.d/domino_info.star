# Map of Domino status codes to (state_str, human_readable)
DOMINO_STATUS = {
    "1": ("OK", "up"),
    "2": ("CRIT", "down"),
    "3": ("CRIT", "not-responding"),
    "4": ("WARN", "crashed"),
    "5": ("UNKNOWN", "unknown"),
}

def main(ctx, params):
    # Discovery mode: single service for the Domino host
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.334.72.2.2"], mutates=False)
        # If we got any response with data, yield one service
        if res.rc == 0 and res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 1 Domino Info service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        # Fallback: try alternate OIDs per DETECT logic (Windows/Net-SNMP)
        for oid in [".1.3.6.1.4.1.8072.3.1.10", ".1.3.6.1.4.1.8072.3.2.10", ".1.3.6.1.4.1.311.1.1.3.1.2"]:
            res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", oid], mutates=False)
            if res.rc == 0 and res.stdout.strip():
                return {
                    "changed": False,
                    "msg": "discovered 1 Domino Info service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
                }
        return {
            "changed": False,
            "msg": "no Domino SNMP data found",
            "data": {"discovery": []},
        }

    # Check mode: fetch domino_info OIDs
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.334.72.2.2",
        ".1.3.6.1.4.1.334.72.1.1.4.8",
        ".1.3.6.1.4.1.334.72.1.1.6.2.1",
        ".1.3.6.1.4.1.334.72.1.1.6.2.4"
    ], mutates=False)

    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "Domino SNMP data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse snmpwalk output: extract first value per OID line
    lines = res.stdout.splitlines()
    values = []
    for line in lines:
        # Format: OID = VALUE or OID.0 = VALUE
        idx = line.find(" = ")
        if idx != -1:
            val = line[idx+3:].strip().strip('"')
            values.append(val)
        else:
            values.append("")

    # We expect 4 values: status, domain, name, release
    if len(values) < 4:
        return {
            "changed": False,
            "msg": "incomplete Domino SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = values[0]
    domain = values[1]
    name = values[2]
    release = values[3]

    # Default to unknown if status code is unexpected
    state_tuple = DOMINO_STATUS.get(status, ("UNKNOWN", "unknown"))
    state, state_readable = state_tuple

    # Build summary line
    summary = "Server is %s" % state_readable
    if domain:
        summary += ", Domain: %s" % domain
    summary += ", Name: %s, %s" % (name, release)

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
