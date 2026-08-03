def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["dsmadmc", "-dataout=yes", "query status"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "dsmadmc not installed", "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "dsmadmc query failed", "data": {"discovery": []}}
        res2 = ctx.run(["dsmadmc", "-dataout=yes", "query scratchpool"], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "cannot query scratch pools", "data": {"discovery": []}}
        out = []
        for line in res2.stdout.splitlines():
            f = line.split()
            if len(f) < 3:
                continue
            library = f[0]
            tapes_str = f[1]
            if not tapes_str.lstrip("-").isdigit():
                continue
            num_tapes = int(tapes_str)
            inst = "default"
            item = library if inst == "default" else (inst + " / " + library)
            out.append({
                "item": item,
                "params": {"levels_lower": params.get("levels_lower", ("fixed", (7, 5)))},
                "metrics": ["tapes_free"],
            })
        return {"changed": False, "msg": "discovered %d scratch pools" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["dsmadmc", "-dataout=yes", "query scratchpool"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "dsmadmc not installed (TSM client missing)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "cannot query TSM scratch pools",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    num_tapes = None
    found_item = False
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 3:
            continue
        library = f[0]
        tapes_str = f[1]
        if not tapes_str.lstrip("-").isdigit():
            continue
        inst = "default"
        cur_item = library if inst == "default" else (inst + " / " + library)
        if cur_item == item:
            found_item = True
            num_tapes = int(tapes_str)
            break
    if not found_item or num_tapes == None:
        return {"changed": False, "msg": "no scratch pool found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels_lower = params.get("levels_lower", ("fixed", (7, 5)))
    warn = None
    crit = None
    if levels_lower != None:
        mode = levels_lower[0]
        vals = levels_lower[1]
        if mode == "fixed" and vals != None:
            warn = vals[0]
            crit = vals[1]
    state = "OK"
    if warn != None and num_tapes <= warn:
        state = "WARN"
    if crit != None and num_tapes <= crit:
        state = "CRIT"
    return {"changed": False,
            "msg": "Found tapes: %d" % num_tapes,
            "data": {"state": state, "metrics": {"tapes_free": num_tapes}, "details": ""}}