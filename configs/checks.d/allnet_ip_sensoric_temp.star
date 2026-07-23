def main(ctx, params):
    # Module-level constants
    TEMP_WARN_DEFAULT = 35.0
    TEMP_CRIT_DEFAULT = 40.0

    # ========== DISCOVERY MODE ==========
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/allnet_ip_sensoric"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read sensor data",
                    "data": {"discovery": []}}

        section = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 3:
                continue
            # Expected format: sensorN name=value function=value unit=value ...
            sensor_id = ""
            data = {}
            for part in parts:
                if "=" in part:
                    key, val = part.split("=", 1)
                    if key == "sensor":
                        sensor_id = val
                    else:
                        data[key] = val
            if sensor_id and "function" in data:
                section[sensor_id] = data

        # Discover temperature sensors (function == "1" OR unit == "°C")
        discovery_items = []
        for sensor_id, sensor_data in sorted(section.items()):
            func = sensor_data.get("function")
            unit = sensor_data.get("unit")
            if func == "1" or unit == "°C":
                num = sensor_id.replace("sensor", "")
                name = sensor_data.get("name", "")
                item = (name + " Sensor " + num) if name else ("Sensor " + num)
                discovery_items.append({
                    "item": item,
                    "params": {"warn": TEMP_WARN_DEFAULT, "crit": TEMP_CRIT_DEFAULT},
                    "metrics": ["temp"]
                })

        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovery_items),
                "data": {"discovery": discovery_items}}

    # ========== CHECK MODE ==========
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/allnet_ip_sensoric"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read sensor data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse section
    section = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 3:
            continue
        sensor_id = ""
        data = {}
        for part in parts:
            if "=" in part:
                key, val = part.split("=", 1)
                if key == "sensor":
                    sensor_id = val
                else:
                    data[key] = val
        if sensor_id and "function" in data:
            section[sensor_id] = data

    # Compute sensor_id from item (reverse of _compose_item)
    sensor_id = "sensor" + item.replace(".+Sensor ", "")
    if item.startswith("Sensor "):
        sensor_id = "sensor" + item.replace("Sensor ", "")
    else:
        # Extract the number after "Sensor " in item
        parts = item.split("Sensor ")
        if len(parts) == 2:
            sensor_id = "sensor" + parts[1]

    if sensor_id not in section:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_data = section[sensor_id]
    if "value_float" not in sensor_data:
        return {"changed": False, "msg": "missing value_float for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp = float(sensor_data["value_float"])

    # Thresholds from params (Checkmk defaults)
    levels = params.get("levels", (TEMP_WARN_DEFAULT, TEMP_CRIT_DEFAULT))
    warn = levels[0]
    crit = levels[1]

    # State determination: upper levels
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"

    return {"changed": False,
            "msg": "Temperature: %f °C" % temp,
            "data": {"state": state,
                     "metrics": {"temp": temp},
                     "details": ""}}
