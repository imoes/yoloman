def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.3417.2.1.1.1.1.1"

    def _pow(base, exp):
        result = 1.0
        i = 0
        while i < int(exp):
            result *= base
            i += 1
        return result

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        data_by_index = {}
        for line in res.stdout.splitlines():
            if len(line.strip()) == 0:
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            full_oid, value_str = parts
            if not full_oid.startswith(base_oid + "."):
                continue
            suffix = full_oid[len(base_oid) + 1:]
            last_dot = suffix.rfind(".")
            if last_dot == -1:
                continue
            oid_suffix = suffix[:last_dot]
            index = suffix[last_dot + 1:]
            value = value_str.strip().strip('"')
            if index not in data_by_index:
                data_by_index[index] = {}
            data_by_index[index][oid_suffix] = value

        temperature_items = []
        other_items = []
        for idx, sensor_data in data_by_index.items():
            if not ("9" in sensor_data and "5" in sensor_data and "7" in sensor_data and "4" in sensor_data and "3" in sensor_data):
                continue
            name = sensor_data["9"]
            reading = sensor_data["5"]
            status = sensor_data["7"]
            scale = sensor_data["4"]
            unit = sensor_data["3"]

            sensor_name = name.replace(" temperature", "")

            scale_float = float(scale) if scale.replace(".", "", 1).lstrip("-").isdigit() else 0.0
            multiplier = _pow(10.0, scale_float)
            value = float(reading) * multiplier if reading.replace(".", "", 1).lstrip("-").isdigit() else 0.0

            is_ok = status == "1"

            if unit == "5":
                temperature_items.append({"item": sensor_name, "params": {}, "metrics": ["temperature"]})
            elif unit == "4":
                other_items.append({"item": sensor_name, "params": {}, "metrics": ["voltage"]})
            else:
                other_items.append({"item": sensor_name, "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(other_items),
            "data": {"discovery": other_items},
        }

    # Check mode (non-discovery)
    item = params.get("item", "")

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

        data_by_index = {}
        for line in res.stdout.splitlines():
            if len(line.strip()) == 0:
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            full_oid, value_str = parts
            if not full_oid.startswith(base_oid + "."):
                continue
            suffix = full_oid[len(base_oid) + 1:]
            last_dot = suffix.rfind(".")
            if last_dot == -1:
                continue
            oid_suffix = suffix[:last_dot]
            index = suffix[last_dot + 1:]
            value = value_str.strip().strip('"')
            if index not in data_by_index:
                data_by_index[index] = {}
            data_by_index[index][oid_suffix] = value

    other_sensors = {}
    for idx, sensor_data in data_by_index.items():
        if not ("9" in sensor_data and "5" in sensor_data and "7" in sensor_data and "4" in sensor_data and "3" in sensor_data):
            continue
        name = sensor_data["9"]
        reading = sensor_data["5"]
        status = sensor_data["7"]
        scale = sensor_data["4"]
        unit = sensor_data["3"]

        sensor_name = name.replace(" temperature", "")

        scale_float = float(scale) if scale.replace(".", "", 1).lstrip("-").isdigit() else 0.0
        multiplier = _pow(10.0, scale_float)
        value = float(reading) * multiplier if reading.replace(".", "", 1).lstrip("-").isdigit() else 0.0

        is_ok = status == "1"

        if unit == "4":
            other_sensors[sensor_name] = {"value": value, "is_ok": is_ok, "is_voltage": True}
        elif unit != "5":
            other_sensors[sensor_name] = {"value": value, "is_ok": is_ok, "is_voltage": False}

    sensor = other_sensors.get(item)
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK" if sensor["is_ok"] else "CRIT"
    summary = "%f" % sensor["value"]
    metrics = {}

    if sensor["is_voltage"]:
        summary = "%f V" % sensor["value"]
        metrics["voltage"] = sensor["value"]

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }