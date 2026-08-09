def _snmpget_oid(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val == "":
        return None
    return val

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base_oid = ".1.3.6.1.4.1.476.1.42.4.3.20"
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    status_oid = base_oid + ".1.1.20.2"

    if params.get("_discover"):
        sys_id = _snmpget_oid(ctx, host, community, sys_oid)
        if sys_id == None:
            return {"changed": False, "msg": "no Liebert device detected", "data": {"discovery": []}}
        if not sys_id.startswith(".1.3.6.1.4.1.476.1.42.4.3.20"):
            return {"changed": False, "msg": "no Liebert chiller detected", "data": {"discovery": []}}
        discovery = [{"item": "", "params": {}, "metrics": ["status"]}]
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": discovery}}

    status_val = _snmpget_oid(ctx, host, community, status_oid)
    if status_val == None:
        return {"changed": False, "msg": "no Liebert chiller status available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metric_val = int(status_val) if status_val.isdigit() else 0
    if status_val in ["5", "7"]:
        return {"changed": False, "msg": "Device is in an OK state", "data": {"state": "OK", "metrics": {"status": metric_val}, "details": ""}}
    else:
        return {"changed": False, "msg": "Device is in a non OK state", "data": {"state": "CRIT", "metrics": {"status": metric_val}, "details": ""}}