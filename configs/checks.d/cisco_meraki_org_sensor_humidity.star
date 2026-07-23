def main(ctx, params):
    # Discover mode: enumerate humidity sensors (one per device with humidity data)
    if params.get("_discover"):
        path = "/var/lib/cisco_meraki/sensors.json"
        if not ctx.file_exists(path):
            return {"changed": False, "msg": "discovered 0 humidity sensors",
                    "data": {"discovery": []}}
        content = ctx.file_read(path)
        if content == "":
            return {"changed": False, "msg": "discovered 0 humidity sensors",
                    "data": {"discovery": []}}
        data = json.decode(content) if content else None
        if data == None or type(data) != "list" or len(data) == 0:
            return {"changed": False, "msg": "discovered 0 humidity sensors",
                    "data": {"discovery": []}}
        items = []
        for device in data:
            if type(device) != "dict":
                continue
            readings = device.get("readings", [])
            if type(readings) != "list":
                continue
            has_humidity = False
            for reading in readings:
                if type(reading) != "dict":
                    continue
                if reading.get("metric") == "humidity":
                    has_humidity = True
                    break
            if has_humidity:
                items.append({"item": "Sensor", "params": {}, "metrics": ["humidity"]})
        return {"changed": False, "msg": "discovered %d humidity sensors" % len(items),
                "data": {"discovery": items}}

    # Check mode: one item (humidity sensor)
    item = params.get("item", "")
    path = "/var/lib/cisco_meraki/sensors.json"
    if not ctx.file_exists(path):
        return {"changed": False, "msg": "no sensor data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    content = ctx.file_read(path)
    if content == "":
        return {"changed": False, "msg": "no sensor data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(content)
    if type(data) != "list":
        return {"changed": False, "msg": "invalid sensor data format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    humidity_value = None
    for device in data:
        if type(device) != "dict":
            continue
        readings = device.get("readings", [])
        if type(readings) != "list":
            continue
        for reading in readings:
            if type(reading) != "dict":
                continue
            if reading.get("metric") == "humidity":
                rel_pct = reading.get("relativePercentage")
                pct = reading.get("percentage")
                if rel_pct != None:
                    if str(rel_pct).isdigit():
                        humidity_value = int(rel_pct)
                elif pct != None:
                    if str(pct).isdigit():
                        humidity_value = int(pct)
                if humidity_value != None:
                    break
        if humidity_value != None:
            break
    if humidity_value == None:
        return {"changed": False, "msg": "no humidity reading available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Default thresholds from Checkmk humidity check
    warn_lo = params.get("levels_lower", 30)
    warn_hi = params.get("levels", 70)
    crit_lo = params.get("levels_lower", 20)
    crit_hi = params.get("levels", 80)
    # Determine state: OK, WARN, CRIT based on humidity value
    if humidity_value <= crit_lo or humidity_value >= crit_hi:
        state = "CRIT"
    elif humidity_value <= warn_lo or humidity_value >= warn_hi:
        state = "WARN"
    else:
        state = "OK"
    msg = "Humidity: %d%%" % humidity_value
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"humidity": humidity_value}, "details": ""}}
