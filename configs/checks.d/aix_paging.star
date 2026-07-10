def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lsps", "-a"], mutates=False)
        lines = res.stdout.splitlines()
        out = []
        for line in lines[1:]:
            if not line.strip():
                continue
            fields = line.split()
            if len(fields) < 6:
                continue
            item = fields[0] + "/" + fields[1]
            out.append({
                "item": item,
                "params": {
                    "levels": (80.0, 90.0),
                    "levels_low": (50.0, 30.0),
                    "magic_norm_size": 4,
                    "show_levels": "onmagic",
                    "show_reserved": True,
                },
                "metrics": ["used_percent"],
            })
        return {"changed": False, "msg": "discovered %d page spaces" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["lsps", "-a"], mutates=False)
    lines = res.stdout.splitlines()
    data = None
    for line in lines[1:]:
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) < 9:
            continue
        if fields[0] + "/" + fields[1] != item:
            continue
        size_str = fields[3]
        if not size_str.endswith("MB"):
            continue
        size_part = size_str[:-2]
        if not size_part.isdigit():
            continue
        size_mb = int(size_part)
        usage_str = fields[4]
        if not usage_str.isdigit():
            continue
        usage = int(usage_str)
        type_map = {"lv": "logical volume", "nfs": "NFS"}
        paging_type = type_map.get(fields[7], "unknown[" + fields[7] + "]")
        data = {
            "size_mb": size_mb,
            "usage_perc": usage,
            "active": fields[5],
            "auto": fields[6],
            "type_": paging_type,
        }
        break
    
    if data == None:
        return {"changed": False, "msg": "page space not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    used_percent = data["usage_perc"]
    warn = params.get("levels", (80.0, 90.0))
    crit = warn[1]
    warn_low = params.get("levels_low", (50.0, 30.0))
    
    state = "OK"
    
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    elif state == "OK" and len(warn_low) >= 2:
        if used_percent <= warn_low[1]:
            state = "CRIT"
        elif used_percent <= warn_low[0]:
            state = "WARN"
    
    summary = "Active: %s, Auto: %s, Type: %s" % (data["active"], data["auto"], data["type_"])
    msg = "%d%% used, %s" % (used_percent, summary)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent},
            "details": "",
        },
    }
