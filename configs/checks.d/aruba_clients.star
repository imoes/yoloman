def main(ctx, params):
    if params.get("_discover"):
        sys_oid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_oid.rc == 127 or not sys_oid.stdout.strip():
            return {"changed": False, "msg": "no snmp agent", "data": {"discovery": [], "host_labels": {}}}
        if not sys_oid.stdout.strip().startswith(".1.3.6.1.4.1.14823"):
            return {"changed": False, "msg": "not an aruba device", "data": {"discovery": [], "host_labels": {}}}
        res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.14823.2.2.1.1.3.2"],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no aruba clients data", "data": {"discovery": [], "host_labels": {}}}
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {"item": "", "params": {"warn": None, "crit": None}, "metrics": ["connections"]},
                ],
                "host_labels": {"cmk/snmp": "yes"},
            },
        }

    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.14823.2.2.1.1.3.2"],
        mutates=False,
    )
    if res.rc == 127 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "aruba clients data not available (no snmp agent / not aruba)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    raw = res.stdout.strip()
    if not raw.isdigit():
        return {
            "changed": False,
            "msg": "could not parse connected clients: %s" % raw,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    clients = int(raw)
    warn = params.get("warn", None)
    crit = params.get("crit", None)
    state = "OK"
    if warn != None and clients >= crit:
        state = "CRIT"
    elif crit != None and clients >= crit:
        state = "CRIT"
    elif warn != None and clients >= warn:
        state = "WARN"
    lvl = ""
    if state == "CRIT":
        lvl = " (crit)"
    elif state == "WARN":
        lvl = " (warn)"
    return {
        "changed": False,
        "msg": "%d WLAN Clients%s" % (clients, lvl),
        "data": {"state": state, "metrics": {"connections": clients}, "details": ""},
    }