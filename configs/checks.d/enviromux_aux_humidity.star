def main(ctx, params):
    # Sensor type map (from Checkmk library)
    SENSOR_TYPE_NAMES = {
        "0": "undefined", "1": "temperature", "2": "humidity", "3": "power",
        "4": "lowVoltage", "5": "current", "6": "aclmvVoltage", "7": "aclmpVoltage",
        "8": "aclmpPower", "9": "water", "10": "smoke", "11": "vibration", "12": "motion",
        "13": "glass", "14": "door", "15": "keypad", "16": "panicButton", "17": "keyStation",
        "18": "digInput", "22": "light", "24": "dewpoint", "26": "tacDio", "36": "acVoltage",
        "37": "acCurrent", "38": "dcVoltage", "39": "dcCurrent", "41": "rmsVoltage",
        "42": "rmsCurrent", "43": "activePower", "44": "reactivePower", "513": "tempHum",
        "32767": "custom", "32769": "temperatureCombo", "32770": "humidityCombo", "540": "tempHum",
    }
    ENVIROMUX_CHECK_DEFAULT_PARAMETERS = {"levels": (15.0, 16.0), "levels_lower": (10.0, 9.0)}

    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # OID suffixes in order: 1=index, 2=type, 3=description, 6=value, 10=min, 11=max
    suffixes = ["1", "2", "3", "6", "10", "11"]
    raw_values = {}
    for suffix in suffixes:
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.3699.1.1.11.1.4.1.1." + suffix
        ], mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            val_part = parts[1].strip()
            # Extract index from OID: last component after last dot
            if "." not in oid:
                continue
            index = oid.rsplit(".", 1)[-1]
            # Remove type prefix like "INTEGER: " or "Gauge32: "
            if ":" in val_part:
                val_part = val_part.split(":", 1)[1].strip()
            # Guard against non-numeric values
            if suffix == "1":
                if not index.isdigit():
                    continue
                val = int(index)
            elif suffix == "2":
                if not val_part.isdigit():
                    continue
                val = int(val_part)
            elif suffix == "6":
                # Check if val_part is numeric
                if not val_part.replace(".", "").isdigit() and not val_part.replace(".", "").replace("-", "").isdigit():
                    continue
                val = float(val_part)
            elif suffix == "10" or suffix == "11":
                # Check if val_part is numeric
                if not val_part.replace(".", "").isdigit() and not val_part.replace(".", "").replace("-", "").isdigit():
                    continue
                val = float(val_part)
            else:
                val = val_part  # description (string)
            # Store raw value
            if index not in raw_values:
                raw_values[index] = {}
            raw_values[index][suffix] = val

    # Rebuild section dict: key = description + " " + index
    section = {}
    for idx, data in raw_values.items():
        if "2" not in data or "6" not in data:
            continue
        description = data.get("3", "")
        if description == None:
            description = ""
        sensor_name = description + " " + idx
        sensor_type = SENSOR_TYPE_NAMES.get(str(data["2"]), "unknown")
        value = float(data["6"])
        min_val = None
        max_val = None
        if "10" in data:
            if str(type(data["10"])) == "int" or str(type(data["10"])) == "float":
                min_val = float(data["10"])
        if "11" in data:
            if str(type(data["11"])) == "int" or str(type(data["11"])) == "float":
                max_val = float(data["11"])

        # Scaling for temperature, power, current, temperatureCombo
        if sensor_type in ["temperature", "power", "current", "temperatureCombo"]:
            value = value / 10.0
            if min_val != None:
                min_val = min_val / 10.0
            if max_val != None:
                max_val = max_val / 10.0

        section[sensor_name] = {"type": sensor_type, "value": value, "min": min_val, "max": max_val}

    # DISCOVERY MODE
    if params.get("_discover"):
        items = []
        for item, sensor in section.items():
            if sensor["type"] in ["humidity", "humidityCombo"]:
                items.append({
                    "item": item,
                    "params": {},
                    "metrics": ["humidity"]
                })
        return {"changed": False, "msg": "discovered %d humidity sensors" % len(items),
                "data": {"discovery": items}}

    # CHECK MODE
    item = params.get("item", "")
    sensor = section.get(item)
    if sensor == None:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Humidity check (using Checkmk's check_humidity logic)
    humidity = sensor["value"]
    warn_upper = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])[0]
    crit_upper = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])[1]
    warn_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])[0]
    crit_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])[1]

    state = "OK"
    if humidity >= crit_upper:
        state = "CRIT"
    elif humidity >= warn_upper:
        state = "WARN"
    elif humidity <= crit_lower:
        state = "CRIT"
    elif humidity <= warn_lower:
        state = "WARN"

    msg = "Humidity: %f%%" % humidity
    details = ""
    if sensor["min"] != None:
        details = details + "Min threshold: %f%%, " % sensor["min"]
    if sensor["max"] != None:
        details = details + "Max threshold: %f%%, " % sensor["max"]
    details = details.rstrip(", ")

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"humidity": humidity}, "details": details}}
