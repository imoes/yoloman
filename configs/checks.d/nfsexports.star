def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["exportfs", "-v"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "exportfs not installed", "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no nfs exports found", "data": {"discovery": []}}
        out = []
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 4:
                continue
            export = f[0]
            if not export.startswith("/"):
                continue
            if export in [e["item"] for e in out]:
                continue
            out.append({"item": export, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d exports" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    res = ctx.run(["exportfs", "-v"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "exportfs not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no nfs exports found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 4:
            continue
        export = f[0]
        if export == item:
            return {"changed": False, "msg": "export is active: %s" % item, "data": {"state": "OK", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "export not found in export list: %s" % item, "data": {"state": "CRIT", "metrics": {}, "details": ""}}