def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["smartctl", "--json=c", "--scan"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no SMART devices found", "data": {"discovery": []}}
        if not res.stdout.strip():
            return {"changed": False, "msg": "no output from smartctl --scan", "data": {"discovery": []}}
        scan = json.decode(res.stdout)
        devices = scan.get("devices", [])
        out = []
        for dev in devices:
            if dev.get("device_type") != "ata":
                continue
            item = dev.get("name", "")
            if not item:
                continue
            out.append({"item": item, "params": {"levels": (35.0, 40.0)}, "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d ATA devices" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["smartctl", "--json=c", "-A", item], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "cannot read SMART attributes for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout.strip():
        return {"changed": False, "msg": "empty output from smartctl -A " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)

    temp_node = data.get("temperature", {})
    current_temp = temp_node.get("current")
    if current_temp == None:
        return {"changed": False, "msg": "no temperature data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn, crit = params.get("levels", (35.0, 40.0))
    state = "OK"
    msg_parts = ["Temperature: %d C" % current_temp]

    if current_temp >= crit:
        state = "CRIT"
        msg_parts.append("(>= %d C)" % crit)
    elif current_temp >= warn:
        state = "WARN"
        msg_parts.append("(>= %d C)" % warn)

    return {"changed": False, "msg": " ".join(msg_parts),
            "data": {"state": state, "metrics": {"temperature": float(current_temp)}, "details": ""}}