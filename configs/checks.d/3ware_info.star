def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["tw_cli", "show"], mutates=False)
        if res.rc == 127 or res.rc != 0:
            return {"changed": False, "msg": "tw_cli not available", "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        controllers = []
        started = False
        for line in lines:
            f = line.split()
            if not started:
                if len(f) == 8 and f[0].startswith("c"):
                    started = True
                    controllers.append({"item": f[0], "params": {}, "metrics": []})
                continue
            if len(f) == 8 and f[0].startswith("c"):
                controllers.append({"item": f[0], "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d controllers" % len(controllers),
                "data": {"discovery": controllers}}

    item = params.get("item", "")
    res = ctx.run(["tw_cli", "show"], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "tw_cli not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    infotext = ""
    found = False
    started = False
    for line in lines:
        f = line.split()
        if not started:
            if len(f) == 8 and f[0].startswith("c"):
                started = True
                if f[0] == item:
                    found = True
                    infotext = infotext + " ".join(f[1:]) + ";"
            continue
        if len(f) == 8 and f[0].startswith("c"):
            if f[0] == item:
                found = True
                infotext = infotext + " ".join(f[1:]) + ";"
    if not found:
        return {"changed": False, "msg": "no such controller: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if infotext == "":
        return {"changed": False, "msg": "no data for controller " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": infotext,
            "data": {"state": "OK", "metrics": {}, "details": ""}}