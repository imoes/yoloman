def main(ctx, params):
    SENSOR_TYPE_NAMES = {
        "0": "undefined", "1": "temperature", "2": "humidity", "3": "power",
        "4": "lowVoltage", "5": "current", "6": "aclmvVoltage", "7": "aclmpVoltage",
        "8": "aclmpPower", "9": "water", "10": "smoke", "11": "vibration",
        "12": "motion", "13": "glass", "14": "door", "15": "keypad",
        "16": "panicButton", "17": "keyStation", "18": "digInput", "22": "light",
        "24": "dewpoint", "26": "tacDio", "36": "acVoltage", "37": "acCurrent",
        "38": "dcVoltage", "39": "dcCurrent", "41": "rmsVoltage", "42": "rmsCurrent",
        "43": "activePower", "44": "reactivePower", "513": "tempHum", "32767": "custom",
        "32769": "temperatureCombo", "32770": "humidityCombo", "540": "tempHum",
    }

    base_oid = ".1.3.6.1.4.1.3699.1.1.9.1.5.1.1"
    oid_index = base_oid + ".1"
    oid_type = base_oid + ".2"
    oid_desc = base_oid + ".3"
    oid_value = base_oid + ".7"
    oid_min = base_oid + ".11"
    oid_max = base_oid + ".12"

    def parse_snmpwalk(res):
        data = {}
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped == "":
                continue
            idx = stripped.find(" = ")
            if idx == -1:
                continue
            oid_part = stripped[:idx]
            val_part = stripped[idx+3:].strip()
            index_str = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
            if val_part.startswith('"') and len(val_part) >= 2 and val_part.endswith('"'):
                val = val_part[1:-1]
            else:
                val = val_part
            data[index_str] = val
        return data

    if params.get("_discover"):
        idx_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                           "-On", params.get("host", "localhost"), oid_index], mutates=False)
        type_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                            "-On", params.get("host", "localhost"), oid_type], mutates=False)
        desc_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                            "-On", params.get("host", "localhost"), oid_desc], mutates=False)
        value_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                             "-On", params.get("host", "localhost"), oid_value], mutates=False)
        min_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                           "-On", params.get("host", "localhost"), oid_min], mutates=False)
        max_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                           "-On", params.get("host", "localhost"), oid_max], mutates=False)

        indices = parse_snmpwalk(idx_res)
        types = parse_snmpwalk(type_res)
        descs = parse_snmpwalk(desc_res)

        items = []
        for idx in indices:
            sensor_type = types.get(idx, "")
            sensor_name = descs.get(idx, "")
            if sensor_type == "2" or sensor_type == "32770":
                if sensor_name == "":
                    sensor_name = idx
                item_name = sensor_name + " " + idx
                suggested_params = {
                    "levels": (65, 70),
                    "levels_lower": (30, 25)
                }
                items.append({
                    "item": item_name,
                    "params": suggested_params,
                    "metrics": ["humidity"]
                })

        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item is required for check mode",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    idx_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), oid_index], mutates=False)
    type_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-On", params.get("host", "localhost"), oid_type], mutates=False)
    desc_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                        "-On", params.get("host", "localhost"), oid_desc], mutates=False)
    value_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), oid_value], mutates=False)
    min_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), oid_min], mutates=False)
    max_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), oid_max], mutates=False)

    indices = parse_snmpwalk(idx_res)
    types = parse_snmpwalk(type_res)
    descs = parse_snmpwalk(desc_res)
    values = parse_snmpwalk(value_res)
    mins = parse_snmpwalk(min_res)
    maxs = parse_snmpwalk(max_res)

    sensor_idx = None
    for idx in indices:
        sensor_name = descs.get(idx, "")
        if sensor_name == "":
            sensor_name = idx
        sensor_item = sensor_name + " " + idx
        if sensor_item == item:
            sensor_idx = idx
            break

    if sensor_idx == None:
        return {
            "changed": False,
            "msg": "humidity sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    type_val = types.get(sensor_idx, "")
    value_val = values.get(sensor_idx, "")
    min_val = mins.get(sensor_idx, "")
    max_val = maxs.get(sensor_idx, "")

    if type_val != "2" and type_val != "32770":
        return {
            "changed": False,
            "msg": "sensor %s is not humidity type" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    humidity_val = 0.0
    if value_val.isdigit():
        humidity_val = float(value_val) / 10.0
    else:
        return {
            "changed": False,
            "msg": "humidity value not numeric: " + str(value_val),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    min_threshold = None
    max_threshold = None
    if min_val.isdigit():
        min_threshold = float(min_val) / 10.0
    if max_val.isdigit():
        max_threshold = float(max_val) / 10.0

    levels = params.get("levels", (65, 70))
    levels_lower = params.get("levels_lower", (30, 25))
    warn_upper = levels[0]
    crit_upper = levels[1]
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]

    state = "OK"
    if crit_upper != None and humidity_val >= crit_upper:
        state = "CRIT"
    elif warn_upper != None and humidity_val >= warn_upper:
        state = "WARN"
    elif crit_lower != None and humidity_val <= crit_lower:
        state = "CRIT"
    elif warn_lower != None and humidity_val <= warn_lower:
        state = "WARN"

    msg = "Humidity: %f%%" % humidity_val
    if min_threshold != None or max_threshold != None:
        msg = msg + " (range %f-%f)" % (min_threshold if min_threshold != None else 0,
                                            max_threshold if max_threshold != None else 100)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity_val},
            "details": ""
        }
    }