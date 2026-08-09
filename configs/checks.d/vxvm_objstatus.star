def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["vxprint", "-ht", "-g"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "vxvm not found on host", "data": {"discovery": [], "host_labels": {}}}
        out = []
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 8:
                continue
            dg_type = f[0]
            dg_name = f[1]
            if dg_type == "v":
                entry = {"item": dg_name, "params": {}, "metrics": []}
                out.append(entry)
        seen = {}
        for e in out:
            seen[e["item"]] = e
        out = list(seen.values())
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["vxprint", "-ht", "-g", item], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "vxvm not found on host", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    volumes = []
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 8:
            continue
        dg_type = f[0]
        dg_name = f[1]
        name = f[2]
        admin_state = f[3]
        kernel_state = f[4]
        if dg_type != "v" or dg_name != item:
            continue
        volumes.append((name, admin_state, kernel_state))
    if len(volumes) == 0:
        return {"changed": False, "msg": "Group not found", "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    state = "OK"
    messages = []
    for volume, admin_state, kernel_state in volumes:
        text = []
        error = False
        if admin_state not in ["CLEAN", "ACTIVE"]:
            if state != "CRIT":
                state = "CRIT"
            text.append("%s: Admin state is %s (!!)" % (volume, admin_state))
            error = True
        if kernel_state not in ["ENABLED", "DISABLED"]:
            if state != "CRIT":
                state = "CRIT"
            text.append("%s: Kernel state is %s (!!)" % (volume, kernel_state))
            error = True
        if not error:
            text = ["%s: OK" % volume]
        messages.append(", ".join(text))
    return {"changed": False, "msg": ", ".join(messages), "data": {"state": state, "metrics": {}, "details": ""}}