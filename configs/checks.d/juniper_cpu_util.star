def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.2636.3.1.13.1"
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        idx_to_descr = {}
        idx_to_util = {}

        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0]
            val_part = parts[1]
            suffix = oid_part.rsplit(".", 1)[-1]
            if not suffix.isdigit():
                continue
            if oid_part.endswith(".5"):
                desc = val_part.strip("\"")
                idx_to_descr[suffix] = desc
            elif oid_part.endswith(".8"):
                if val_part.isdigit():
                    util = int(val_part)
                    idx_to_util[suffix] = util

        items = []
        for idx, util in idx_to_util.items():
            if util == 0:
                continue
            desc = idx_to_descr.get(idx, "CPU " + str(idx))
            clean_item = desc.replace("@ ", "").replace("/*", "").strip()
            items.append({"item": clean_item, "params": {"levels": (80.0, 90.0)}, "metrics": ["util"]})

        return {"changed": False, "msg": "discovered %d CPUs" % len(items), "data": {"discovery": items}}

    item = params.get("item", "")
    levels = params.get("levels", (80.0, 90.0))
    warn, crit = levels[0], levels[1]

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    idx_to_descr = {}
    idx_to_util = {}

    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0]
        val_part = parts[1]
        suffix = oid_part.rsplit(".", 1)[-1]
        if not suffix.isdigit():
            continue
        if oid_part.endswith(".5"):
            desc = val_part.strip("\"")
            idx_to_descr[suffix] = desc
        elif oid_part.endswith(".8"):
            if val_part.isdigit():
                util = int(val_part)
                idx_to_util[suffix] = util

    util_value = None
    for idx, util in idx_to_util.items():
        if util == 0:
            continue
        desc = idx_to_descr.get(idx, "CPU " + str(idx))
        clean_item = desc.replace("@ ", "").replace("/*", "").strip()
        if clean_item == item:
            util_value = util
            break

    if util_value == None:
        return {"changed": False, "msg": "CPU item '%s' not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    if util_value >= crit:
        state = "CRIT"
    elif util_value >= warn:
        state = "WARN"

    msg = "CPU utilization: %d%%" % util_value
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"util": util_value}, "details": ""}}