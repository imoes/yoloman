def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.12962.1.1"
    col_oid = "8"

    if params.get("_discover"):
        sys_oid = ".1.3.6.1.2.1.1.1.0"
        sys_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Ov", host, sys_oid], mutates=False)
        if sys_res.rc != 0 or sys_res.skipped:
            return {"changed": False, "msg": "no Decru device found",
                    "data": {"discovery": [], "host_labels": {}}}
        sys_val = sys_res.stdout.strip()
        if "datafort" not in sys_val:
            return {"changed": False, "msg": "no Decru device found",
                    "data": {"discovery": [], "host_labels": {}}}
        full_oid = base_oid + "." + col_oid
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, full_oid], mutates=False)
        if res.rc != 0 or res.skipped:
            return {"changed": False, "msg": "no Decru CPU data found",
                    "data": {"discovery": [], "host_labels": {}}}
        vals = res.stdout.splitlines()
        if len(vals) != 5:
            return {"changed": False, "msg": "incomplete CPU data",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "discovered cpu",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["user", "system", "interrupt"]}
                ]}}

    item = params.get("item", "")
    full_oid = base_oid + "." + col_oid
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, full_oid], mutates=False)
    if res.rc != 0 or res.skipped:
        return {"changed": False, "msg": "no Decru device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vals = res.stdout.splitlines()
    if len(vals) != 5:
        return {"changed": False, "msg": "incomplete CPU data: got %d values" % len(vals),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    try_val = []
    ok = True
    for v in vals:
        v = v.strip()
        if v == "" or (v.startswith("-") and v[1:].isdigit()) or v.isdigit():
            try_val.append(v)
        else:
            ok = False
            break
    if not ok:
        return {"changed": False, "msg": "non-numeric CPU value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    user = float(vals[0]) / 10.0
    nice = float(vals[1]) / 10.0
    system = float(vals[2]) / 10.0
    interrupt = float(vals[3]) / 10.0
    idle = float(vals[4]) / 10.0
    user += nice
    return {"changed": False,
            "msg": "user %f%%, sys %f%%, interrupt %f%%, idle %f%%" % (user, system, interrupt, idle),
            "data": {"state": "OK",
                     "metrics": {"user": user, "system": system, "interrupt": interrupt, "idle": idle},
                     "details": ""}}