def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["svcinfo", "lsmdisk", "-nohdr", "-delim", ":"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "svcinfo not available",
                    "data": {"discovery": []}}
        out = []
        seen = {}
        for line in res.stdout.splitlines():
            f = line.split(":")
            if len(f) < 5:
                continue
            if f[0] in ["id", "node_id", "mdisk_id", "enclosure_id"]:
                continue
            name = f[1]
            if name not in seen:
                seen[name] = True
                out.append({"item": name, "params": _default_params(),
                            "metrics": []})
        return {"changed": False, "msg": "discovered %d mdisks" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    res = ctx.run(["svcinfo", "lsmdisk", item, "-nohdr", "-delim", ":"],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "mdisk not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    f = res.stdout.split(":")
    if len(f) < 3:
        return {"changed": False, "msg": "no data for mdisk: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    mdisk_status = f[2]
    mdisk_mode = f[3]
    p = _default_params()
    status_state = p.get(mdisk_status + "_state", 1)
    mode_state = p.get(mdisk_mode + "_mode", 1)
    if status_state >= mode_state:
        v = status_state
    else:
        v = mode_state
    if v == 0:
        s = "OK"
    elif v == 1:
        s = "WARN"
    elif v == 2:
        s = "CRIT"
    else:
        s = "UNKNOWN"
    return {"changed": False,
            "msg": "Status: " + mdisk_status + ", Mode: " + mdisk_mode,
            "data": {"state": s, "metrics": {},
                     "details": "Status: " + mdisk_status + ", Mode: " + mdisk_mode}}


def _default_params():
    return {
        "online_state": 0,
        "degraded_state": 1,
        "offline_state": 2,
        "excluded_state": 2,
        "empty_state": 2,
        "managed_mode": 0,
        "array_mode": 0,
        "image_mode": 0,
        "unmanaged_mode": 1,
    }