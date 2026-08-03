def _empty():
    return []

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["hpss", "status"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no HP MSA system found",
                    "data": {"discovery": [], "host_labels": {}}}
        parsed = {}
        current_name = None
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            section = parts[0]
            if section != "system":
                continue
            key = parts[2]
            value = " ".join(parts[3:])
            if key == "system-name":
                current_name = value
                parsed[current_name] = {"item_type": parts[0], "health-numeric": "0", "health-reason": ""}
            elif current_name != None:
                if key == "health-numeric":
                    parsed[current_name]["health-numeric"] = value
                elif key == "health-reason":
                    parsed[current_name]["health-reason"] = value
        discovery = []
        for system_name in parsed:
            discovery.append({"item": system_name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}

    item = params.get("item", "")
    res = ctx.run(["hpss", "status"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no HP MSA system found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = {}
    current_name = None
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        section = parts[0]
        if section != "system":
            continue
        key = parts[2]
        value = " ".join(parts[3:])
        if key == "system-name":
            current_name = value
            parsed[current_name] = {"item_type": parts[0], "health-numeric": "0", "health-reason": ""}
        elif current_name != None:
            if key == "health-numeric":
                parsed[current_name]["health-numeric"] = value
            elif key == "health-reason":
                parsed[current_name]["health-reason"] = value

    if item not in parsed:
        return {"changed": False, "msg": "System not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = parsed[item]
    health_numeric = int(data["health-numeric"]) if data["health-numeric"].isdigit() else 0
    reason = data["health-reason"]

    if health_numeric == 0:
        state = "OK"
        msg = "Health: OK"
    elif health_numeric == 1:
        state = "WARN"
        msg = "Health: Warning - " + reason
    elif health_numeric >= 2:
        state = "CRIT"
        msg = "Health: Critical - " + reason
    else:
        state = "UNKNOWN"
        msg = "Unknown health state: " + str(health_numeric)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {}, "details": reason}}