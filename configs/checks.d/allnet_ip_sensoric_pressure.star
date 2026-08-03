def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-Oqn", params.get("host", "localhost"),
                       ".1.3.6.1.4.1.1.8.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovery failed: %s" % res.stderr,
                    "data": {"discovery": []}}
        sensors = _parse_sensors(res.stdout)
        discovery = []
        for sensor_id in sorted(sensors.keys()):
            sensor_data = sensors[sensor_id]
            if not _match_function_or_unit(sensor_data, "16", "hpa"):
                continue
            discovery.append({
                "item": _compose_item(sensor_id, sensor_data),
                "params": {},
                "metrics": ["pressure"],
            })
        return {"changed": False,
                "msg": "discovered %d pressure sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-Oqn", params.get("host", "localhost"),
                   ".1.3.6.1.4.1.1.8.0"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False,
                "msg": "no sensor data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sensors = _parse_sensors(res.stdout)
    sensor_id = _item_to_sensor_id(item)
    if sensor_id == None or sensor_id not in sensors:
        return {"changed": False,
                "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sensor_data = sensors[sensor_id]
    if not _match_function_or_unit(sensor_data, "16", "hpa"):
        return {"changed": False,
                "msg": "sensor is not a pressure sensor",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if "value_float" not in sensor_data:
        return {"changed": False,
                "msg": "sensor value missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value_text = sensor_data["value_float"]
    if not _is_float(value_text):
        return {"changed": False,
                "msg": "invalid sensor value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    pressure = float(value_text) / 1000
    return {"changed": False,
            "msg": "%f bar" % pressure,
            "data": {"state": "OK",
                     "metrics": {"pressure": pressure},
                     "details": ""}}


def _match_function_or_unit(sensor_data, function, unit):
    return (sensor_data.get("function") == function or
            (unit != None and sensor_data.get("unit") == unit))


def _compose_item(sensor_id, sensor):
    num = sensor_id.replace("sensor", "")
    if "name" in sensor:
        return sensor["name"] + " Sensor " + num
    return "Sensor " + num


def _item_to_sensor_id(item):
    idx = item.find(" Sensor ")
    if idx == -1:
        return None
    num = item[idx + len(" Sensor "):]
    return "sensor" + num


def _is_float(s):
    if s == None or s == "":
        return False
    text = s
    if text.startswith("-"):
        text = text[1:]
    if text == "":
        return False
    parts = text.split(".", 1)
    if len(parts) == 2:
        left = parts[0]
        right = parts[1]
        if left != "" and not left.isdigit():
            return False
        if right != "" and not right.isdigit():
            return False
        if left == "" and right == "":
            return False
        return True
    if not text.isdigit():
        return False
    return True


def _parse_sensors(stdout):
    sensors = {}
    lines = stdout.split("\n")
    for line in lines:
        line = line.strip()
        if line == "":
            continue
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1]
        field_parts = oid.split(".")
        if len(field_parts) < 9:
            continue
        sensor_num = field_parts[8]
        field = field_parts[9]
        if not _is_int(sensor_num) or not _is_int(field):
            continue
        sensor_id = "sensor" + sensor_num
        if sensor_id not in sensors:
            sensors[sensor_id] = {}
        s = sensors[sensor_id]
        if field == "1":
            s["name"] = value
        elif field == "2":
            s["function"] = value
        elif field == "3":
            s["unit"] = value
        elif field == "4":
            s["value_float"] = value
    return sensors


def _is_int(s):
    if s == None or s == "":
        return False
    if s.startswith("-"):
        rest = s[1:]
    else:
        rest = s
    return rest.isdigit()