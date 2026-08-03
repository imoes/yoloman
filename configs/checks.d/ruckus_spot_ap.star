def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["which", "ruckus_spot_cli"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "Ruckus Spot not found on host",
                    "data": {"discovery": []}}
        json_res = ctx.run(["ruckus_spot_cli", "--json", "ap-status"], mutates=False)
        if json_res.rc != 0 or not json_res.stdout:
            return {"changed": False, "msg": "Ruckus Spot not reachable",
                    "data": {"discovery": []}}
        data = json.decode(json_res.stdout)
        bands = {}
        for band_info in data:
            band = _BANDS_MAP.get(str(band_info.get("band", "")))
            if band == None:
                continue
            aps = band_info.get("access_points", [])
            devs = []
            for ap in aps:
                devs.append({"name": str(ap["name"]), "status": int(ap["status"])})
            if band not in bands:
                bands[band] = []
            bands[band] = bands[band] + devs
        discovery = []
        for band in sorted(bands.keys()):
            discovery.append({
                "item": band,
                "params": {},
                "metrics": ["ap_devices_total"],
            })
        return {"changed": False, "msg": "discovered %d bands" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["which", "ruckus_spot_cli"], mutates=False)
    if res.rc != 0 or not item:
        return {"changed": False, "msg": "Ruckus Spot not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    json_res = ctx.run(["ruckus_spot_cli", "--json", "ap-status"], mutates=False)
    if json_res.rc != 0 or not json_res.stdout:
        return {"changed": False, "msg": "Ruckus Spot not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(json_res.stdout)
    devices = []
    for band_info in data:
        band = _BANDS_MAP.get(str(band_info.get("band", "")))
        if band != item:
            continue
        aps = band_info.get("access_points", [])
        for ap in aps:
            devices.append({"name": str(ap["name"]), "status": int(ap["status"])})

    if len(devices) == 0:
        return {"changed": False, "msg": "no devices found for band %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {"ap_devices_total": len(devices)}
    drifted = 0
    not_responding = 0
    for d in devices:
        if d["status"] == 2:
            drifted = drifted + 1
        if d["status"] == 0:
            not_responding = not_responding + 1
    metrics["ap_devices_drifted"] = drifted
    metrics["ap_devices_not_responding"] = not_responding

    levels_total = params.get("ap_devices_total", None)
    levels_drifted = params.get("levels_drifted", None)
    levels_not_responding = params.get("levels_not_responding", None)

    state = "OK"

    if levels_total != None:
        warn, crit = levels_total
        if len(devices) >= crit:
            state = "CRIT"
        elif len(devices) >= warn:
            if state != "CRIT":
                state = "WARN"

    if levels_drifted != None:
        warn, crit = levels_drifted
        if drifted >= crit:
            state = "CRIT"
        elif drifted >= warn:
            if state != "CRIT":
                state = "WARN"

    if levels_not_responding != None:
        warn, crit = levels_not_responding
        if not_responding >= crit:
            state = "CRIT"
        elif not_responding >= warn:
            if state != "CRIT":
                state = "WARN"

    msg = "Devices: %d, Drifted: %d, Not responding: %d" % (len(devices), drifted, not_responding)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}


_BANDS_MAP = {
    "1": "2.4 GHz",
    "2": "5 GHz",
}