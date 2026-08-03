def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    levels = params.get("levels_ppm", (10, 25))
    warn = levels[0] if len(levels) > 0 else 10
    crit = levels[1] if len(levels) > 1 else 25

    if params.get("_discover"):
        sys_descr = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_descr.rc != 0 or not sys_descr.stdout.strip():
            return {"changed": False, "msg": "no SNMP response",
                    "data": {"discovery": []}}
        sys_oid = sys_descr.stdout.strip()
        kentix_prefix = ".1.3.6.1.4.1.332.11.6"
        if not sys_oid.startswith(kentix_prefix):
            return {"changed": False, "msg": "not a Kentix device",
                    "data": {"discovery": []}}

        co1 = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host,
             ".1.3.6.1.4.1.37954.2.1.4.1"], mutates=False)
        if co1.rc != 0 or not co1.stdout.strip():
            return {"changed": False, "msg": "no CO sensor found",
                    "data": {"discovery": []}}

        return {"changed": False, "msg": "discovered Carbon Monoxide",
                "data": {"discovery": [
                    {"item": "", "params": {"levels_ppm": (10, 25)},
                     "metrics": ["parts_per_million"]}
                ]}}

    sys_descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sys_descr.rc != 0 or not sys_descr.stdout.strip():
        return {"changed": False, "msg": "no SNMP response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_oid = sys_descr.stdout.strip()
    kentix_prefix = ".1.3.6.1.4.1.332.11.6"
    if not sys_oid.startswith(kentix_prefix):
        return {"changed": False, "msg": "not a Kentix device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.4.1.37954.2.1.4.1"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no CO reading available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val = res.stdout.strip()
    ppm = int(val) if val.lstrip("-").isdigit() else None

    if ppm == None:
        return {"changed": False, "msg": "cannot parse CO value: " + val,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    if ppm >= crit:
        state = "CRIT"
    elif ppm >= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "%d ppm CO concentration" % ppm,
            "data": {"state": state, "metrics": {"parts_per_million": ppm},
                     "details": ""}}