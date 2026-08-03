def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.3697.1.10.10.1.15.2.0"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "no quantum libsmall library found", "data": {"discovery": [], "host_labels": {}}}
        value = res.stdout.strip()
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}], "host_labels": {}}}
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.4.1.3697.1.10.10.1.15.2.0"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "no quantum libsmall library found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "Quantum Small Library Product not found"}}
    value = res.stdout.strip()
    if value == "1":
        return {"changed": False, "msg": "Library door open", "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    if value == "2":
        return {"changed": False, "msg": "Library door closed", "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "Library door unknown", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}