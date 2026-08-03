def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = "1.3.6.1.4.1.15497.1.1.1.3.0"
    base = "1.3.6.1.4.1.15497.1.1.1"

    # Probe for the real thing: this OID lives on Cisco SMA devices. We treat
    # absence of the SNMP responder or the OID as "not present".
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        if params.get("_discover"):
            return {"changed": False, "msg": "Cisco SMA not reachable, no items discovered",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "disk IO utilization not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = float(res.stdout.strip())

    if params.get("_discover"):
        # Single-service check: one item with empty name.
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["disk_io_utilization"]}]}}

    levels = params.get("upper_levels", [80.0, 90.0])
    # Accept either ("fixed", (warn, crit)) or a bare list/tuple.
    if type(levels) == "list" and len(levels) == 2:
        warn = levels[0]
        crit = levels[1]
    elif type(levels) == "tuple" and len(levels) == 2 and type(levels[1]) == "list":
        warn = levels[1][0]
        crit = levels[1][1]
    elif type(levels) == "list" and len(levels) == 1:
        warn = levels[0]
        crit = levels[0]
    else:
        warn = 80.0
        crit = 90.0

    state = "CRIT" if value >= crit else ("WARN" if value >= warn else "OK")
    return {"changed": False, "msg": "Total Disk IO Utilization: %f%%" % value,
            "data": {"state": state, "metrics": {"disk_io_utilization": value}, "details": ""}}