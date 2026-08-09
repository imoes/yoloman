def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["svcinfo", "lsci", "-nohdr", "-bytes", "power_watt", "temperature_celsius"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "svcinfo not found", "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "svcinfo failed", "data": {"discovery": []}}
        out = []
        enclosure_ids = {}
        for line in res.stdout.splitlines():
            f = line.split()
            if len(f) < 2:
                continue
            enclosure_ids[f[0]] = True
        for enc_id in enclosure_ids:
            out.append({"item": enc_id, "params": {}, "metrics": ["power"]})
        return {"changed": False, "msg": "discovered %d enclosures" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["svcinfo", "lsci", "-nohdr", "-bytes", "power_watt", "temperature_celsius"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "svcinfo not found: IBM SVC not present", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "svcinfo failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found = False
    stat_current = None
    for line in res.stdout.splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        if f[0] == item:
            stat_current = f[1]
            found = True
            break

    if not found or stat_current == None:
        return {"changed": False, "msg": "no such enclosure: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    power = int(stat_current) if stat_current.lstrip("-").isdigit() else 0
    return {"changed": False, "msg": "%s Watt" % power, "data": {"state": "OK", "metrics": {"power": power}, "details": ""}}