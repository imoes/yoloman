def main(ctx, params):
    res = ctx.run(["svcinfo", "lsenclosurestats", "-delim", ":"], mutates=False)

    if res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "svcinfo failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    enclosures = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(":")
        if len(parts) < 3:
            continue
        enc_id = parts[0]
        if enc_id == "enclosure_id":
            continue
        stat_name = parts[1]
        stat_current_str = parts[2].strip()
        if not stat_current_str.isdigit():
            continue
        stat_current = int(stat_current_str)
        if enc_id not in enclosures:
            enclosures[enc_id] = {}
        if stat_name not in enclosures[enc_id]:
            enclosures[enc_id][stat_name] = stat_current

    if params.get("_discover"):
        items = []
        for enc_id, enc_stats in enclosures.items():
            if "power_w" in enc_stats:
                items.append({
                    "item": enc_id,
                    "params": {},
                    "metrics": ["power"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    enc_data = enclosures.get(item)
    if enc_data == None:
        return {
            "changed": False,
            "msg": "enclosure not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    power_w = enc_data.get("power_w")
    if power_w == None:
        return {
            "changed": False,
            "msg": "power_w stat missing for enclosure " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "%d Watt" % power_w,
        "data": {"state": "OK", "metrics": {"power": power_w}, "details": ""},
    }