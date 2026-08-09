def main(ctx, params):
    # SNMP base OID for enviromux_all_external section
    base_oid = ".1.3.6.1.4.1.3699.1.1.11.1.21.1.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Sensor type names mapping
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

    # Default thresholds for voltage (from ENVIROMUX_CHECK_DEFAULT_PARAMETERS)
    voltage_levels = params.get("levels", [15.0, 16.0])
    voltage_levels_lower = params.get("levels_lower", [10.0, 9.0])

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base_oid + ".1",  # allExternalSensorIndex
            base_oid + ".3",  # allExternalSensorType
            base_oid + ".4",  # allExternalSensorDescription
            base_oid + ".8",  # allExternalSensorValue
            base_oid + ".10", # allExternalSensorMinThreshold
            base_oid + ".11", # allExternalSensorMaxThreshold
        ], mutates=False)

        # Parse snmpwalk output - we need to handle the format: "OID = TYPE: value"
        lines = res.stdout.splitlines()
        sensor_data = {}
        i = 0
        while i < len(lines) - 5:
            # Parse each line: "oid = type: value"
            parts_idx = lines[i].split(" = ")
            parts_type = lines[i+1].split(" = ")
            parts_desc = lines[i+2].split(" = ")
            parts_val = lines[i+3].split(" = ")
            parts_min = lines[i+4].split(" = ")
            parts_max = lines[i+5].split(" = ")

            if len(parts_idx) < 2 or len(parts_type) < 2 or len(parts_desc) < 2 or len(parts_val) < 2:
                i = i + 6
                continue

            # Extract value part after "type: "
            def get_value(line_part):
                if ": " in line_part:
                    return line_part.split(": ", 1)[1].strip()
                return line_part.strip()

            idx = get_value(parts_idx[1])
            type_id = get_value(parts_type[1])
            description = get_value(parts_desc[1])
            value_raw = get_value(parts_val[1])
            min_raw = get_value(parts_min[1])
            max_raw = get_value(parts_max[1])

            # Parse value safely - no try/except allowed
            val_parts = value_raw.split(maxsplit=1)
            value = 0.0
            if len(val_parts) > 0:
                val_str = val_parts[0]
                # Check if string is numeric
                is_valid = False
                if val_str.isdigit():
                    is_valid = True
                elif val_str.startswith("-") and len(val_str) > 1 and val_str[1:].isdigit():
                    is_valid = True
                elif "." in val_str:
                    parts_decimal = val_str.split(".")
                    if len(parts_decimal) == 2 and parts_decimal[0].isdigit() and parts_decimal[1].isdigit():
                        is_valid = True
                    elif len(parts_decimal) == 2 and parts_decimal[0].startswith("-") and parts_decimal[0][1:].isdigit() and parts_decimal[1].isdigit():
                        is_valid = True
                if is_valid:
                    value = float(val_str)
                else:
                    i = i + 6
                    continue
            else:
                i = i + 6
                continue

            # Create sensor item name
            item_name = description + " " + idx
            sensor_type = SENSOR_TYPE_NAMES.get(type_id, "unknown")

            # Build metrics list based on type
            metrics = []
            if sensor_type in ["temperature", "temperatureCombo"]:
                metrics = ["temp", "temp_critical", "temp_warning"]
            elif sensor_type == "humidity":
                metrics = ["humidity"]
            elif sensor_type == "power":
                metrics = ["voltage"]

            # Determine parameters based on type
            sensor_params = {}
            if sensor_type in ["temperature", "temperatureCombo"]:
                sensor_params = {}
            elif sensor_type == "humidity":
                sensor_params = {}
            elif sensor_type == "power":
                sensor_params = {
                    "levels": voltage_levels,
                    "levels_lower": voltage_levels_lower
                }

            sensor_data[item_name] = {
                "item": item_name,
                "params": sensor_params,
                "metrics": metrics,
            }
            i = i + 6

        # Build discovery result
        out = []
        for item_name, data in sensor_data.items():
            out.append(data)

        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(out),
            "data": {"discovery": out}
        }

    # Check mode (single item)
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch sensor data via snmpwalk and filter for the specific item
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        base_oid
    ], mutates=False)

    lines = res.stdout.splitlines()
    sensor = None
    i = 0
    while i < len(lines) - 5:
        # Parse the same way as discovery
        parts_idx = lines[i].split(" = ")
        parts_type = lines[i+1].split(" = ")
        parts_desc = lines[i+2].split(" = ")
        parts_val = lines[i+3].split(" = ")
        parts_min = lines[i+4].split(" = ")
        parts_max = lines[i+5].split(" = ")

        if len(parts_idx) < 2 or len(parts_type) < 2 or len(parts_desc) < 2 or len(parts_val) < 2:
            i = i + 6
            continue

        def get_value(line_part):
            if ": " in line_part:
                return line_part.split(": ", 1)[1].strip()
            return line_part.strip()

        idx = get_value(parts_idx[1])
        type_id = get_value(parts_type[1])
        description = get_value(parts_desc[1])
        value_raw = get_value(parts_val[1])
        min_raw = get_value(parts_min[1])
        max_raw = get_value(parts_max[1])

        # Create item name
        item_name = description + " " + idx

        if item_name != item:
            i = i + 6
            continue

        # Parse value safely
        val_parts = value_raw.split(maxsplit=1)
        value = 0.0
        if len(val_parts) > 0:
            val_str = val_parts[0]
            is_valid = False
            if val_str.isdigit():
                is_valid = True
            elif val_str.startswith("-") and len(val_str) > 1 and val_str[1:].isdigit():
                is_valid = True
            elif "." in val_str:
                parts_decimal = val_str.split(".")
                if len(parts_decimal) == 2 and parts_decimal[0].isdigit() and parts_decimal[1].isdigit():
                    is_valid = True
                elif len(parts_decimal) == 2 and parts_decimal[0].startswith("-") and parts_decimal[0][1:].isdigit() and parts_decimal[1].isdigit():
                    is_valid = True
            if is_valid:
                value = float(val_str)
            else:
                return {
                    "changed": False,
                    "msg": "invalid sensor value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
        else:
            return {
                "changed": False,
                "msg": "invalid sensor value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }

        # Parse min/max thresholds safely
        min_threshold = None
        if min_raw != "" and len(min_raw.split(maxsplit=1)) > 0:
            min_raw_val = min_raw.split(maxsplit=1)[0]
            is_valid = False
            if min_raw_val.isdigit():
                is_valid = True
            elif min_raw_val.startswith("-") and len(min_raw_val) > 1 and min_raw_val[1:].isdigit():
                is_valid = True
            elif "." in min_raw_val:
                parts_decimal = min_raw_val.split(".")
                if len(parts_decimal) == 2 and parts_decimal[0].isdigit() and parts_decimal[1].isdigit():
                    is_valid = True
                elif len(parts_decimal) == 2 and parts_decimal[0].startswith("-") and parts_decimal[0][1:].isdigit() and parts_decimal[1].isdigit():
                    is_valid = True
            if is_valid:
                min_threshold = float(min_raw_val)

        max_threshold = None
        if max_raw != "" and len(max_raw.split(maxsplit=1)) > 0:
            max_raw_val = max_raw.split(maxsplit=1)[0]
            is_valid = False
            if max_raw_val.isdigit():
                is_valid = True
            elif max_raw_val.startswith("-") and len(max_raw_val) > 1 and max_raw_val[1:].isdigit():
                is_valid = True
            elif "." in max_raw_val:
                parts_decimal = max_raw_val.split(".")
                if len(parts_decimal) == 2 and parts_decimal[0].isdigit() and parts_decimal[1].isdigit():
                    is_valid = True
                elif len(parts_decimal) == 2 and parts_decimal[0].startswith("-") and parts_decimal[0][1:].isdigit() and parts_decimal[1].isdigit():
                    is_valid = True
            if is_valid:
                max_threshold = float(max_raw_val)

        sensor = {
            "type_": SENSOR_TYPE_NAMES.get(type_id, "unknown"),
            "value": value,
            "min_threshold": min_threshold,
            "max_threshold": max_threshold
        }
        break
        i = i + 6

    # If sensor not found
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Process based on sensor type
    sensor_type = sensor["type_"]
    value = sensor["value"]
    min_threshold = sensor["min_threshold"]
    max_threshold = sensor["max_threshold"]

    state = "OK"
    metrics = {}
    details = ""

    # Temperature
    if sensor_type in ["temperature", "temperatureCombo"]:
        warn = params.get("levels_upper", [30.0, 35.0])  # Checkmk temperature defaults
        crit = params.get("levels", [35.0, 40.0])       # This is reversed in Checkmk; actual is levels_upper, levels

        # Apply thresholds - Checkmk uses levels for upper bounds, levels_lower for lower bounds
        upper_warn = warn[0] if len(warn) >= 1 else 30.0
        upper_crit = warn[1] if len(warn) >= 2 else 35.0
        lower_warn = params.get("levels_lower", [15.0, 10.0])[0] if len(params.get("levels_lower", [15.0, 10.0])) >= 1 else 15.0
        lower_crit = params.get("levels_lower", [15.0, 10.0])[1] if len(params.get("levels_lower", [15.0, 10.0])) >= 2 else 10.0

        # Use device thresholds if available
        if max_threshold != None:
            upper_warn = max_threshold
            upper_crit = max_threshold
        if min_threshold != None:
            lower_warn = min_threshold
            lower_crit = min_threshold

        if value >= upper_crit or value <= lower_crit:
            state = "CRIT"
        elif value >= upper_warn or value <= lower_warn:
            state = "WARN"

        metrics["temp"] = value
        details = "Temperature: %s" % value

    # Humidity
    elif sensor_type == "humidity":
        humidity_warn = params.get("levels", [60.0, 80.0])[0] if len(params.get("levels", [60.0, 80.0])) >= 1 else 60.0
        humidity_crit = params.get("levels", [60.0, 80.0])[1] if len(params.get("levels", [60.0, 80.0])) >= 2 else 80.0

        if value >= humidity_crit:
            state = "CRIT"
        elif value >= humidity_warn:
            state = "WARN"

        metrics["humidity"] = value
        details = "Humidity: %s%%" % value

    # Voltage/Power
    elif sensor_type == "power":
        # Use voltage defaults from ENVIROMUX_CHECK_DEFAULT_PARAMETERS
        warn = params.get("levels", voltage_levels)
        crit = params.get("levels", voltage_levels)
        warn_lower = params.get("levels_lower", voltage_levels_lower)
        crit_lower = params.get("levels_lower", voltage_levels_lower)

        upper_warn = warn[0] if len(warn) >= 1 else 15.0
        upper_crit = warn[1] if len(warn) >= 2 else 16.0
        lower_warn = warn_lower[0] if len(warn_lower) >= 1 else 10.0
        lower_crit = warn_lower[1] if len(warn_lower) >= 2 else 9.0

        # Use device thresholds if available
        if max_threshold != None:
            upper_warn = max_threshold
            upper_crit = max_threshold
        if min_threshold != None:
            lower_warn = min_threshold
            lower_crit = min_threshold

        if value >= upper_crit or value <= lower_crit:
            state = "CRIT"
        elif value >= upper_warn or value <= lower_warn:
            state = "WARN"

        metrics["voltage"] = value
        details = "Voltage: %s V" % value

    # Default handling for unknown types
    else:
        state = "OK"
        details = "Sensor type: " + sensor_type + ", Value: " + value

    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
