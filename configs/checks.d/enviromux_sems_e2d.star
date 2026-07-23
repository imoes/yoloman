def main(ctx, params):
    # Constants defined at module top level (Starlark requirement)
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

    # Discovery mode
    if params.get("_discover"):
        # Get SNMP parameters
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        # Fetch sensor data via SNMP
        base_oid = ".1.3.6.1.4.1.3699.1.1.9.1.4.1.1"
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            base_oid + ".1",  # intSensorIndex
            base_oid + ".2",  # intSensorType
            base_oid + ".3",  # intSensorDescription
            base_oid + ".6",  # intSensorValue
            base_oid + ".10", # intSensorMinThreshold
            base_oid + ".11", # intSensorMaxThreshold
        ], mutates=False)

        # Parse SNMP output into sensor data
        sensor_index = {}
        sensor_type = {}
        sensor_desc = {}
        sensor_value = {}
        sensor_min = {}
        sensor_max = {}

        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            eq_idx = line.find(" = ")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            value_part = line[eq_idx+3:].strip()
            if ":" in value_part:
                value = value_part.split(":", 1)[1].strip()
            else:
                value = value_part

            suffix = oid_part.rsplit(".", 1)[-1]

            if oid_part.endswith(".1"):
                sensor_index[suffix] = value
            elif oid_part.endswith(".2"):
                sensor_type[suffix] = value
            elif oid_part.endswith(".3"):
                sensor_desc[suffix] = value
            elif oid_part.endswith(".6"):
                sensor_value[suffix] = value
            elif oid_part.endswith(".10"):
                sensor_min[suffix] = value
            elif oid_part.endswith(".11"):
                sensor_max[suffix] = value

        # Process sensors
        discovered = []
        for suffix in sensor_index:
            sensor_name = sensor_desc.get(suffix, "") + " " + sensor_index.get(suffix, "")
            sensor_type_str = SENSOR_TYPE_NAMES.get(sensor_type.get(suffix, "0"), "unknown")

            # Skip sensors that cannot be parsed (guard instead of try)
            val_str = sensor_value.get(suffix, "")
            if not val_str.isdigit() and not (val_str.replace(".", "").replace("-", "").isdigit() if val_str.count("-") <= 1 else False):
                continue
            
            sensor_val = float(val_str)

            # Apply scaling for temperature/power/current/temperatureCombo
            if sensor_type_str in ["temperature", "power", "current", "temperatureCombo"]:
                sensor_val /= 10.0

            # Parse min/max thresholds
            min_str = sensor_min.get(suffix, "")
            max_str = sensor_max.get(suffix, "")
            sensor_min_val = None
            sensor_max_val = None

            if min_str and (min_str.isdigit() or (min_str.replace(".", "").replace("-", "").isdigit() if min_str.count("-") <= 1 else False)):
                sensor_min_val = float(min_str)
                if sensor_type_str in ["temperature", "power", "current", "temperatureCombo"]:
                    sensor_min_val /= 10.0

            if max_str and (max_str.isdigit() or (max_str.replace(".", "").replace("-", "").isdigit() if max_str.count("-") <= 1 else False)):
                sensor_max_val = float(max_str)
                if sensor_type_str in ["temperature", "power", "current", "temperatureCombo"]:
                    sensor_max_val /= 10.0

            # Only discover temperature sensors
            if sensor_type_str in ["temperature", "temperatureCombo"]:
                params_dict = {"levels": (26.0, 30.0), "levels_lower": (15.0, 10.0)}
                if sensor_min_val != None and sensor_max_val != None:
                    params_dict["dev_levels_lower"] = (sensor_min_val, sensor_min_val)
                    params_dict["dev_levels"] = (sensor_max_val, sensor_max_val)
                discovered.append({
                    "item": sensor_name,
                    "params": params_dict,
                    "metrics": ["temp"]
                })

        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode
    item = params.get("item", "")

    # Get SNMP parameters
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Fetch all sensor data via SNMP
    base_oid = ".1.3.6.1.4.1.3699.1.1.9.1.4.1.1"
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        base_oid + ".1",  # intSensorIndex
        base_oid + ".2",  # intSensorType
        base_oid + ".3",  # intSensorDescription
        base_oid + ".6",  # intSensorValue
        base_oid + ".10", # intSensorMinThreshold
        base_oid + ".11", # intSensorMaxThreshold
    ], mutates=False)

    # Parse SNMP output
    sensor_data = {}

    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        eq_idx = line.find(" = ")
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx].strip()
        value_part = line[eq_idx+3:].strip()
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip()
        else:
            value = value_part

        suffix = oid_part.rsplit(".", 1)[-1]

        if oid_part.endswith(".1"):
            sensor_data.setdefault(suffix, {})["index"] = value
        elif oid_part.endswith(".2"):
            sensor_data.setdefault(suffix, {})["type"] = value
        elif oid_part.endswith(".3"):
            sensor_data.setdefault(suffix, {})["desc"] = value
        elif oid_part.endswith(".6"):
            sensor_data.setdefault(suffix, {})["value"] = value
        elif oid_part.endswith(".10"):
            sensor_data.setdefault(suffix, {})["min"] = value
        elif oid_part.endswith(".11"):
            sensor_data.setdefault(suffix, {})["max"] = value

    # Find the specific sensor by item name
    sensor = None
    for suffix, data in sensor_data.items():
        sensor_name = data.get("desc", "") + " " + data.get("index", "")
        if sensor_name == item:
            sensor = data
            break

    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse sensor data
    sensor_type_str = SENSOR_TYPE_NAMES.get(sensor.get("type", "0"), "unknown")

    # Guard before parsing value (no try)
    val_str = sensor.get("value", "")
    if not val_str.isdigit() and not (val_str.replace(".", "").replace("-", "").isdigit() if val_str.count("-") <= 1 else False):
        return {
            "changed": False,
            "msg": "sensor value invalid",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    sensor_val = float(val_str)

    # Apply scaling for temperature
    if sensor_type_str in ["temperature", "temperatureCombo"]:
        sensor_val /= 10.0

    # Parse min/max thresholds
    min_str = sensor.get("min", "")
    max_str = sensor.get("max", "")
    sensor_min_val = None
    sensor_max_val = None

    if min_str and (min_str.isdigit() or (min_str.replace(".", "").replace("-", "").isdigit() if min_str.count("-") <= 1 else False)):
        sensor_min_val = float(min_str)
        if sensor_type_str in ["temperature", "power", "current", "temperatureCombo"]:
            sensor_min_val /= 10.0

    if max_str and (max_str.isdigit() or (max_str.replace(".", "").replace("-", "").isdigit() if max_str.count("-") <= 1 else False)):
        sensor_max_val = float(max_str)
        if sensor_type_str in ["temperature", "power", "current", "temperatureCombo"]:
            sensor_max_val /= 10.0

    # Extract thresholds from params (Checkmk defaults)
    warn_high = params.get("levels", (26.0, 30.0))[1]
    crit_high = params.get("levels", (26.0, 30.0))[0]
    warn_low = params.get("levels_lower", (15.0, 10.0))[1]
    crit_low = params.get("levels_lower", (15.0, 10.0))[0]

    # Use device thresholds if available
    if sensor_min_val != None:
        warn_low = sensor_min_val
        crit_low = sensor_min_val
    if sensor_max_val != None:
        warn_high = sensor_max_val
        crit_high = sensor_max_val

    # Determine state
    state = "OK"
    msg_parts = ["Temperature: %f C" % sensor_val]

    if sensor_val >= crit_high:
        state = "CRIT"
        msg_parts.append("CRIT (>= %f)" % crit_high)
    elif sensor_val >= warn_high:
        state = "WARN"
        msg_parts.append("WARN (>= %f)" % warn_high)

    if sensor_val <= crit_low:
        state = "CRIT"
        msg_parts.append("CRIT (<= %f)" % crit_low)
    elif sensor_val <= warn_low:
        state = "WARN"
        msg_parts.append("WARN (<= %f)" % warn_low)

    # Build metrics dict
    metrics = {"temp": sensor_val}

    if sensor_min_val != None:
        metrics["temp_min"] = sensor_min_val
    if sensor_max_val != None:
        metrics["temp_max"] = sensor_max_val

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
