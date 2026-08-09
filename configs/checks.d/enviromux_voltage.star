SENSOR_TYPE_NAMES = {
    "0": "undefined",
    "1": "temperature",
    "2": "humidity",
    "3": "power",
    "4": "lowVoltage",
    "5": "current",
    "6": "aclmvVoltage",
    "7": "aclmpVoltage",
    "8": "aclmpPower",
    "9": "water",
    "10": "smoke",
    "11": "vibration",
    "12": "motion",
    "13": "glass",
    "14": "door",
    "15": "keypad",
    "16": "panicButton",
    "17": "keyStation",
    "18": "digInput",
    "22": "light",
    "24": "dewpoint",
    "26": "tacDio",
    "36": "acVoltage",
    "37": "acCurrent",
    "38": "dcVoltage",
    "39": "dcCurrent",
    "41": "rmsVoltage",
    "42": "rmsCurrent",
    "43": "activePower",
    "44": "reactivePower",
    "513": "tempHum",
    "32767": "custom",
    "32769": "temperatureCombo",
    "32770": "humidityCombo",
    "540": "tempHum",
}

ENVIROMUX_CHECK_DEFAULT_PARAMETERS = {
    "levels": [15.0, 16.0],
    "levels_lower": [10.0, 9.0],
}

def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.3699.1.1.11.1.3.1.1"
    if ctx.facts().get("distribution", "") == "enviromux5":
        base_oid = ".1.3.6.1.4.1.3699.1.1.10.1.3.1.1"

    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base_oid
        ], mutates=False)

        sensor_data = {}
        for field_oid in ["1", "2", "3", "6", "10", "11"]:
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", community,
                "-On", host,
                base_oid + "." + field_oid
            ], mutates=False)

            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) < 2:
                    continue
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                
                oid_numbers = oid_part.split(".")
                if len(oid_numbers) < 10:
                    continue
                sensor_index_str = oid_numbers[-1]
                if not sensor_index_str.isdigit():
                    continue
                sensor_index = int(sensor_index_str)

                if value_part.startswith("STRING:"):
                    value = value_part[7:].strip().strip('"')
                elif value_part.startswith("INTEGER:"):
                    value = value_part[8:].strip()
                elif value_part.startswith("Gauge32:"):
                    value = value_part[8:].strip()
                elif value_part.startswith("Counter32:"):
                    value = value_part[10:].strip()
                else:
                    value = value_part.strip()

                if sensor_index not in sensor_data:
                    sensor_data[sensor_index] = {}

                sensor_data[sensor_index][int(field_oid)] = value

        discovered_items = []
        for sensor_index in sorted(sensor_data.keys()):
            sensor = sensor_data[sensor_index]
            sensor_type = sensor.get(2, "0")
            sensor_description = sensor.get(3, "")
            sensor_type_name = SENSOR_TYPE_NAMES.get(sensor_type, "unknown")

            if sensor_type_name == "power":
                item = sensor_description + " " + str(sensor_index)
                discovered_items.append({
                    "item": item,
                    "params": ENVIROMUX_CHECK_DEFAULT_PARAMETERS,
                    "metrics": ["voltage"]
                })

        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(discovered_items),
            "data": {"discovery": discovered_items}
        }

    item = params.get("item", "")
    levels = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])
    levels_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])

    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        base_oid + ".2"
    ], mutates=False)

    sensor_value = None
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        oid_numbers = oid_part.split(".")
        if len(oid_numbers) < 10:
            continue
        sensor_index_str = oid_numbers[-1]
        if not sensor_index_str.isdigit():
            continue
        sensor_index = int(sensor_index_str)

        if value_part.startswith("STRING:"):
            sensor_description = value_part[7:].strip().strip('"')
        else:
            continue

        if item.startswith(sensor_description):
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", community,
                "-On", host,
                base_oid + ".6." + str(sensor_index)
            ], mutates=False)

            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) < 2:
                    continue
                value_part = parts[1].strip()
                
                if value_part.startswith("STRING:"):
                    sensor_value_str = value_part[7:].strip()
                elif value_part.startswith("INTEGER:"):
                    sensor_value_str = value_part[8:].strip()
                elif value_part.startswith("Gauge32:"):
                    sensor_value_str = value_part[8:].strip()
                else:
                    sensor_value_str = value_part.strip()

                if sensor_value_str.isdigit() or (sensor_value_str.startswith("-") and sensor_value_str[1:].isdigit()):
                    sensor_value = float(sensor_value_str) / 10.0
                break
            break

    if sensor_value == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state = "OK"

    if levels_lower[0] != None and sensor_value <= levels_lower[0]:
        state = "CRIT"
    elif levels_lower[1] != None and sensor_value <= levels_lower[1]:
        state = "WARN"

    if levels[0] != None and sensor_value >= levels[0]:
        state = "CRIT"
    elif levels[1] != None and sensor_value >= levels[1]:
        state = "WARN"

    msg_parts = []
    msg_parts.append("Voltage: %f V" % sensor_value)
    if levels_lower[0] != None:
        msg_parts.append("low: %f" % levels_lower[0])
    if levels[0] != None:
        msg_parts.append("high: %f" % levels[0])
    msg = ", ".join(msg_parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"voltage": sensor_value},
            "details": ""
        }
    }
