def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn, crit = params.get("levels", (40000, 50000))

    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2620.1.1.25.3"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no check point device found", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {"levels": (warn, crit)}, "metrics": ["connections"]}]}}

    item = params.get("item", "")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.2620.1.1.25.3"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no check point device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val = res.stdout.strip()
    if not val or not val.lstrip("-").isdigit():
        return {"changed": False, "msg": "no check point device found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    current = int(val)
    state = "CRIT" if current >= crit else ("WARN" if current >= warn else "OK")
    return {"changed": False, "msg": "Current connections: %d" % current, "data": {"state": state, "metrics": {"connections": current}, "details": ""}}