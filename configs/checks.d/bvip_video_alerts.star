# Translated Checkmk check: bvip_video_alerts
# Monitors Bosch VIP video device alarm state via SNMP.

def _get_sys_descr(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.skipped or res.rc != 0:
        return None
    return res.stdout

def _is_bvip(descr):
    if descr == None:
        return False
    for marker in ["flexidome", "vip-x", "dinion", "autodome"]:
        if descr.find(marker) >= 0:
            return True
    return False

def _walk_tree(ctx, host, community, base):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base],
        mutates=False,
    )
    if res.skipped or res.rc != 0 or not res.stdout.strip():
        return {}
    col1 = {}
    col3 = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1]
        if oid.find(base + ".1.1.3.1.") == 0:
            idx = oid[len(base + ".1.1.3.1"):]
            col1[idx] = val
        elif oid.find(base + ".3.1.1.") == 0:
            idx = oid[len(base + ".3.1.1"):]
            col3[idx] = val
    return {"col1": col1, "col3": col3}

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.3967.1"

    if params.get("_discover"):
        descr = _get_sys_descr(ctx, host, community)
        if not _is_bvip(descr):
            return {"changed": False, "msg": "not a BVIP device",
                    "data": {"discovery": []}}
        tree = _walk_tree(ctx, host, community, base)
        if not tree:
            return {"changed": False, "msg": "no video alert items found",
                    "data": {"discovery": []}}
        out = []
        for idx in sorted(tree["col1"].keys()):
            raw_item = tree["col1"].get(idx, "")
            item = raw_item.replace("\x00", "")
            out.append({"item": item, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    # CHECK MODE
    descr = _get_sys_descr(ctx, host, community)
    if not _is_bvip(descr):
        return {"changed": False, "msg": "not a BVIP device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")
    tree = _walk_tree(ctx, host, community, base)
    if not tree:
        return {"changed": False, "msg": "no video alert data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_idx = None
    for idx, name in tree["col1"].items():
        if name.replace("\x00", "") == item:
            target_idx = idx
            break
    if target_idx == None:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    alerts = tree["col3"].get(target_idx, "0")
    if alerts != "0":
        return {"changed": False, "msg": "Device on Alarm State",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": "No alarms",
            "data": {"state": "OK", "metrics": {}, "details": ""}}