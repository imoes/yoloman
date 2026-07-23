def main(ctx, params):
    # Check if discovery mode
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {"util": (80.0, 90.0)}, "metrics": ["util"]}
                ]
            },
        }

    # Check mode: get CPU utilization via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    oid = ".1.3.6.1.4.1.6141.2.60.12.1.11.9"

    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, oid
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse SNMP output: expect "OID = INTEGER: value"
    util = None
    for line in res.stdout.splitlines():
        idx = line.find(" = INTEGER: ")
        if idx != -1:
            value_str = line[idx + len(" = INTEGER: "):].strip()
            if value_str.isdigit():
                util = int(value_str)

    # If util is still None, report UNKNOWN
    if util == None:
        return {
            "changed": False,
            "msg": "could not parse CPU utilization",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply thresholds from params (Checkmk defaults)
    warn, crit = params.get("util", (80.0, 90.0))

    # Determine state: util is integer percentage
    state = "OK"
    if util >= crit:
        state = "CRIT"
    elif util >= warn:
        state = "WARN"

    msg = "CPU utilization: %d%%" % util

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"util": util},
            "details": ""
        },
    }
