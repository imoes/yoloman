def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.2.3.51.2.2.7"
    state_oid = base + ".1.0"
    descr_oid = base + ".2.1.3.1"

    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, state_oid], mutates=False)
        if res.rc == 127 or res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "blade health not available",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [{"item": "", "params": {},
                                        "metrics": []}]}}

    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, state_oid], mutates=False)
    if res.rc == 127 or res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no blade health state reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = res.stdout.strip()

    dres = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqvt", host, descr_oid], mutates=False)
    descr = ""
    if dres.rc == 0 and dres.stdout.strip():
        val = dres.stdout.strip()
        if val.startswith("STRING: "):
            val = val[len("STRING: "):]
        val = val.strip().strip('"')
        descr = ": " + val

    if state == "255":
        return {"changed": False, "msg": "State is good",
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    if state == "2":
        return {"changed": False, "msg": "State is degraded (non critical)" + descr,
                "data": {"state": "WARN", "metrics": {}, "details": ""}}
    if state == "4":
        return {"changed": False, "msg": "State is degraded (system level)" + descr,
                "data": {"state": "WARN", "metrics": {}, "details": ""}}
    if state == "0":
        return {"changed": False, "msg": "State is critical!" + descr,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False,
            "msg": "Undefined state code %s%s" % (state, descr),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}