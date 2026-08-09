def main(ctx, params):
    if params.get("_discover"):
        sys_oid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", "-OvQ", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid.rc != 0:
            return {"changed": False, "msg": "bdtms not detected", "data": {"discovery": []}}
        if ".1.3.6.1.4.1.20884.77.83.1" not in sys_oid.stdout:
            return {"changed": False, "msg": "bdtms not detected", "data": {"discovery": []}}
        base = ".1.3.6.1.4.1.20884.2"
        act = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", "-OvQ", params.get("host", "localhost"), base + ".1"], mutates=False)
        health = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", "-OvQ", params.get("host", "localhost"), base + ".3"], mutates=False)
        if act.rc != 0 or health.rc != 0:
            return {"changed": False, "msg": "cannot fetch bdtms status OIDs", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]
            },
        }
    base = ".1.3.6.1.4.1.20884.2"
    health_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", "-OvQ", params.get("host", "localhost"), base + ".3"], mutates=False)
    if health_res.rc != 0:
        return {"changed": False, "msg": "cannot fetch bdtms tape status", "data": {"state": "UNKNOWN", "metrics": {}, "details": "snmpget rc=%d" % health_res.rc}}
    health_id = health_res.stdout.strip()
    health = {
        "1": "unknown",
        "2": "ok",
        "3": "warning",
        "4": "critical",
    }.get(health_id, "unknown")
    state = {
        "unknown": "UNKNOWN",
        "ok": "OK",
        "warning": "WARN",
        "critical": "CRIT",
    }.get(health, "UNKNOWN")
    return {"changed": False, "msg": health, "data": {"state": state, "metrics": {}, "details": ""}}