def main(ctx, params):
    if params.get("_discover"):
        api_key = params.get("api_key", "")
        host = params.get("host", "api.meraki.com")
        org_id = params.get("org_id", "")
        network_id = params.get("network_id", "")
        serial = params.get("serial", "")

        if not api_key or not org_id or not network_id or not serial:
            return {"changed": False, "msg": "Meraki credentials not configured",
                    "data": {"discovery": []}}

        url = "/api/v1/networks/" + network_id + "/devices/" + serial + "/sensorController/status"
        res = ctx.run(["curl", "-s", "-H", "X-Cisco-Meraki-API-Key: " + api_key,
                       "-H", "Content-Type: application/json",
                       "https://" + host + url], mutates=False)

        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "Meraki API unreachable",
                    "data": {"discovery": []}}

        data = json.decode(res.stdout)

        has_battery = False
        if type(data) == "dict" and "readings" in data:
            readings = data["readings"]
            for i in range(len(readings)):
                reading = readings[i]
                if type(reading) == "dict" and reading.get("metric") == "battery":
                    has_battery = True
                    break

        if not has_battery:
            return {"changed": False, "msg": "No battery reading found",
                    "data": {"discovery": []}}

        return {"changed": False,
                "msg": "discovered 1 battery sensor",
                "data": {"discovery": [
                    {"item": "Sensor",
                     "params": {},
                     "metrics": ["battery_capacity", "last_reported"]}
                ]}}

    item = params.get("item", "")
    if item != "Sensor":
        return {"changed": False, "msg": "Unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    api_key = params.get("api_key", "")
    host = params.get("host", "api.meraki.com")
    org_id = params.get("org_id", "")
    network_id = params.get("network_id", "")
    serial = params.get("serial", "")

    if not api_key or not org_id or not network_id or not serial:
        return {"changed": False, "msg": "Meraki credentials not configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    url = "/api/v1/networks/" + network_id + "/devices/" + serial + "/sensorController/status"
    res = ctx.run(["curl", "-s", "-H", "X-Cisco-Meraki-API-Key: " + api_key,
                   "-H", "Content-Type: application/json",
                   "https://" + host + url], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "Meraki API unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout)

    percentage = None
    ts_raw = None
    if type(data) == "dict" and "readings" in data:
        readings = data["readings"]
        for i in range(len(readings)):
            reading = readings[i]
            if type(reading) == "dict" and reading.get("metric") == "battery":
                raw_battery = reading.get("battery", {})
                if type(raw_battery) == "dict":
                    if "percentage" in raw_battery:
                        percentage = raw_battery["percentage"]
                    elif "relativePercentage" in raw_battery:
                        percentage = raw_battery["relativePercentage"]
                    ts_raw = raw_battery.get("ts")
                break

    if percentage == None:
        return {"changed": False, "msg": "No battery percentage reading available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("warn", 20)
    crit = params.get("crit", 10)
    levels_lower = params.get("levels_lower", (crit, warn))

    # levels_lower is a tuple (crit, warn) for lower-level checks
    # percentage: WARN if <= warn, CRIT if <= crit
    if percentage <= levels_lower[0]:
        state = "CRIT"
    elif percentage <= levels_lower[1]:
        state = "WARN"
    else:
        state = "OK"

    metrics = {"battery_capacity": percentage}

    msg = "Battery: %d%%" % percentage

    details = ""
    if ts_raw:
        details = "Battery timestamp: " + str(ts_raw)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}