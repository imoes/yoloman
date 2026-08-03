def main(ctx, params):
    if params.get("_discover"):
        sys_oid = _snmpget(ctx, params, "1.3.6.1.2.1.1.2.0")
        if sys_oid == None or sys_oid == "":
            return {"changed": False, "msg": "Bintec not detected",
                    "data": {"discovery": []}}
        if sys_oid != ".1.3.6.1.4.1.272.4.200.83.88.67.66.0.0" and \
           sys_oid != ".1.3.6.1.4.1.272.4.158.82.78.66.48.0.0":
            return {"changed": False, "msg": "Bintec not detected",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}]}}

    res1 = _snmpget(ctx, params, "1.3.6.1.4.1.272.4.1.26.0")
    res2 = _snmpget(ctx, params, "1.3.6.1.4.1.272.4.1.31.0")
    if res1 == None or res2 == None:
        return {"changed": False, "msg": "No data retrieved",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False,
            "msg": "Serial: %s, Software: %s" % (res2, res1),
            "data": {"state": "OK", "metrics": {}, "details": ""}}


def _snmpget(ctx, params, oid):
    res = ctx.run(["snmpget", "-v2c", "-c",
                   params.get("community", "public"), "-Oqv",
                   params.get("host", "localhost"), oid],
                  mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()