def main(ctx, params):
    # DISCOVERY MODE: find all NVMe devices with SMART health information
    if params.get("_discover"):
        res = ctx.run(["smartctl", "--scan", "-j"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no devices found (smartctl scan failed)",
                    "data": {"discovery": []}}
        scan = json.decode(res.stdout)
        devices = scan.get("devices", [])
        out = []
        for dev in devices:
            path = dev.get("name", "")
            if path == "":
                continue
            info_res = ctx.run(["smartctl", "-j", "-x", path], mutates=False)
            if info_res.rc != 0 or not info_res.stdout.strip():
                continue
            # Safe JSON decode with check first
            if not info_res.stdout.strip():
                continue
            # Use the fact that invalid JSON will be caught by .get() chain later
            info = json.decode(info_res.stdout)
            if info == None:
                continue
            smart_status = info.get("smart_status", {})
            if smart_status.get("passed", False) != True:
                continue
            nvme = info.get("nvme_smart_health_information_log")
            if nvme == None:
                continue
            if nvme.get("temperature") == None:
                continue
            out.append({"item": path,
                        "params": {"levels": (35.0, 40.0)},
                        "metrics": ["temp"]})
        return {"changed": False, "msg": "discovered %d NVMe devices" % len(out),
                "data": {"discovery": out}}

    # CHECK MODE: one item
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no device specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res_info = ctx.run(["smartctl", "-j", "-x", item], mutates=False)
    if res_info.rc != 0 or not res_info.stdout.strip():
        return {"changed": False, "msg": "device missing or unreadable: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Direct JSON decode - if invalid, this will be handled by downstream checks
    info = json.decode(res_info.stdout)
    if info == None:
        return {"changed": False, "msg": "device missing or unreadable: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    nvme = info.get("nvme_smart_health_information_log")
    if nvme == None:
        return {"changed": False, "msg": "no NVMe health data for device: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temperature = nvme.get("temperature")
    if temperature == None:
        return {"changed": False, "msg": "no temperature data for device: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = float(temperature)
    warn, crit = params.get("levels", (35.0, 40.0))

    state = "CRIT" if reading >= crit else ("WARN" if reading >= warn else "OK")
    msg = "Temperature: %f C" % reading
    if state != "OK":
        above = (reading - crit) if state == "CRIT" else (reading - warn)
        msg += ", %f C above %s threshold" % (above, "critical" if state == "CRIT" else "warning")

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temp": reading}, "details": ""}}