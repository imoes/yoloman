def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn", 90.0)
    crit = params.get("crit", 95.0)
    oid_base = ".1.3.6.1.4.1.6486.801.1.2.1.16.1.1.1.1.1"
    oid_col = "15"

    sys_oid = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host,
        ".1.3.6.1.2.1.1.2.0",
    ], mutates=False)
    if sys_oid.rc != 0 or not sys_oid.stdout.strip():
        if params.get("_discover"):
            return {"changed": False, "msg": "not an Alcatel AOS7 device",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False,
                "msg": "Alcatel AOS7 CPU: device not reachable or not Alcatel",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_val = sys_oid.stdout.strip()
    if not sys_val.startswith(".1.3.6.1.4.1.6486.801"):
        if params.get("_discover"):
            return {"changed": False, "msg": "not an Alcatel AOS7 device",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False,
                "msg": "Alcatel AOS7 CPU: sysObjectID does not match Alcatel AOS7",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-Oqv", host,
        oid_base + "." + oid_col,
    ], mutates=False)
    if cpu_res.rc != 0 or not cpu_res.stdout.strip():
        if params.get("_discover"):
            return {"changed": False, "msg": "Alcatel AOS7 device present but CPU OID not available",
                    "data": {"discovery": [{"item": "", "params": {"warn": warn, "crit": crit},
                            "metrics": ["util"]}]}}
        return {"changed": False,
                "msg": "Alcatel AOS7 CPU: unable to read CPU utilization OID",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = cpu_res.stdout.strip()
    val = raw
    for prefix in ["INTEGER:", "COUNTER32:", "COUNTER64:", "GAUGE:"]:
        if val.startswith(prefix):
            val = val[len(prefix):].strip()
            break
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]

    cpu_val = 0
    parsed = False
    digits = val.lstrip("-")
    if digits.isdigit():
        cpu_val = int(val)
        parsed = True
    else:
        parts = val.split()
        if parts and parts[0].lstrip("-").isdigit():
            cpu_val = int(parts[0])
            parsed = True

    if not parsed:
        if params.get("_discover"):
            return {"changed": False,
                    "msg": "Alcatel AOS7 CPU: unparseable value '%s'" % raw,
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "Alcatel AOS7 CPU: unparseable value '%s'" % raw,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {"warn": warn, "crit": crit},
                        "metrics": ["util"]}]}}

    state = "OK"
    if cpu_val >= crit:
        state = "CRIT"
    elif cpu_val >= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "Total %d%%" % cpu_val,
            "data": {"state": state, "metrics": {"util": cpu_val}, "details": ""}}