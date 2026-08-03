def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["dsmadmc", "-id=admin", "-pass=admin"], mutates=False)
        installed = res.rc == 0 and res.stdout.find("IBM Tivoli Storage Manager") >= 0
        if not installed:
            return {"changed": False, "msg": "tsm not installed", "data": {"discovery": []}}
        # The on-host data source is the dsmadmc query command.
        # We cannot reproduce the exact <<<tsm_storagepool>>> agent section without
        # TSM installed, so we probe via the same underlying query the agent plugin would.
        q = ctx.run(["dsmadmc", "-id=admin", "-pass=admin", "query status"], mutates=False)
        if q.rc != 0:
            return {"changed": False, "msg": "tsm query failed", "data": {"discovery": []}}
        # The real section data is produced by the TSM agent plugin; without it we
        # rely on the parsed section passed via params. Since the agent section is
        # not available here, we read it through the section data passed in params.
        section = params.get("_section", {})
        out = []
        for item in section:
            out.append({"item": item, "params": {}, "metrics": ["used_space"]})
        return {"changed": False, "msg": "discovered %d storagepools" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    section = params.get("_section", {})
    data = section.get(item)
    if data == None:
        return {"changed": False,
                "msg": "no such storagepool: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    size = int(float(data["size"]) * 1024 * 1024)
    kb = float(size) / 1024.0
    if kb >= 1048576:
        ds = "%f TB" % (kb / 1048576.0)
    elif kb >= 1024:
        ds = "%f GB" % (kb / 1024.0)
    elif kb >= 1:
        ds = "%f MB" % kb
    else:
        ds = "%f KB" % (kb * 1024.0)
    summary = "Used size: %s, Type: %s" % (ds, data["type"])
    return {"changed": False,
            "msg": summary,
            "data": {"state": "OK", "metrics": {"used_space": size}, "details": ""}}