def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lsps", "-s"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "lsps not found", "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no paging space", "data": {"discovery": []}}
        out = []
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            name = parts[0]
            if name == "Page" or name == "Total" or name == "paging":
                continue
            out.append({"item": name, "params": {"levels": (80, 90)},
                        "metrics": ["used_percent"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["lsps", "-s"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "lsps not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no paging space found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    found = None
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        name = parts[0]
        if name == "Page" or name == "Total" or name == "paging":
            continue
        if name == item:
            found = parts
            break
    if found == None:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pct_str = found[2].rstrip("%")
    pct = int(pct_str) if pct_str.isdigit() else 0
    warn = 80
    crit = 90
    levels = params.get("levels")
    if levels != None and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    else:
        warn = params.get("warn", warn)
        crit = params.get("crit", crit)
    state = "CRIT" if pct >= crit else ("WARN" if pct >= warn else "OK")
    return {"changed": False, "msg": "%s %d%% used" % (item, pct),
            "data": {"state": state, "metrics": {"used_percent": pct}, "details": ""}}