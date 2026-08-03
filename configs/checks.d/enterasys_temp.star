def main(ctx, params):
    if params.get("_discover"):
        sysOid = _get_scalar(".1.3.6.1.2.1.1.2.0", ctx, params)
        if not sysOid:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        if not (sysOid.startswith(".1.3.6.1.4.1.5624.2.1") or sysOid.startswith(".1.3.6.1.4.1.5624.2.2")):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        temp = _get_scalar(".1.3.6.1.4.1.52.4.1.1.8.1.1", ctx, params)
        if temp == None:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        if temp == "0":
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        warn = params.get("warn", 30.0)
        crit = params.get("crit", 35.0)
        return {"changed": False, "msg": "discovered 1 items", "data": {"discovery": [{"item": "Ambient", "params": {"warn": warn, "crit": crit}, "metrics": ["temperature"]}]}}
    temp = _get_scalar(".1.3.6.1.4.1.52.4.1.1.8.1.1", ctx, params)
    if temp == None or temp == "0":
        return {"changed": False, "msg": "Sensor broken or not supported", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = 0.0
    if temp.lstrip("-").isdigit():
        raw = int(temp) / 10.0
    warn = params.get("warn", 30.0)
    crit = params.get("crit", 35.0)
    if raw >= crit:
        state = "CRIT"
    elif raw >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "Temperature %f F" % raw, "data": {"state": state, "metrics": {"temperature": raw}, "details": ""}}


def _get_scalar(oid, ctx, params):
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()