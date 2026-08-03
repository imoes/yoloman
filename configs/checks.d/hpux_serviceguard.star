def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cmclquery", "clp"], mutates=False)
        if res.rc == 127 or res.rc == 1:
            return {"changed": False, "msg": "hpux_serviceguard not installed",
                    "data": {"discovery": []}}
        out = []
        lines = res.stdout.splitlines()
        for line in lines:
            fields = line.split("|")
            if len(fields) == 1 and fields[0].strip().startswith("summary="):
                out.append({"item": "Total Status", "params": {},
                            "metrics": []})
            elif len(fields) == 2:
                out.append({"item": fields[0], "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d serviceguard items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["cmclquery", "clp"], mutates=False)
    if res.rc == 127 or res.rc == 1:
        return {"changed": False,
                "msg": "hpux_serviceguard not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    for line in res.stdout.splitlines():
        fields = line.split("|")
        if (item == "Total Status" and len(fields) == 1 and
                fields[0].strip().startswith("summary=")):
            status = fields[-1].split("=")[-1].strip()
            state = "OK" if status == "ok" else ("WARN" if status == "degraded" else "CRIT")
            return {"changed": False,
                    "msg": "Serviceguard %s: state is %s" % (item, status),
                    "data": {"state": state, "metrics": {}, "details": ""}}
        elif item == fields[0] and len(fields) == 2:
            status = fields[-1].split("=")[-1].strip()
            state = "OK" if status == "ok" else ("WARN" if status == "degraded" else "CRIT")
            return {"changed": False,
                    "msg": "Serviceguard %s: state is %s" % (item, status),
                    "data": {"state": state, "metrics": {}, "details": ""}}
    return {"changed": False,
            "msg": "Serviceguard %s: No such item found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}