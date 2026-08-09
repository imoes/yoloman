# Module-level constants
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
    base_oid = ".1.3.6.1.4.1.3699.1.1.2.1.5.1.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discovery mode: fetch all sensors
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1",  # extSensorIndex
            base_oid + ".2",  # extSensorType
            base_oid + ".3",  # extSensorDescription
            base_oid + ".7",  # extSensorValue
            base_oid + ".11", # extSensorMinThreshold
            base_oid + ".12", # extSensorMaxThreshold
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed", 
                    "data": {"discovery": []}}

        # Parse SNMP output (format: OID = TYPE: value)
        lines = res.stdout.splitlines()
        data = {}
        # Group lines by sensor index (first 6 OIDs per sensor)
        i = 0
        while i + 5 < len(lines):
            # Extract index, type, description, value, min, max
            def parse_value(line):
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    return None
                val = parts[1]
                # Handle different types (INTEGER, STRING, Gauge32, etc.)
                if val.startswith("INTEGER: "):
                    return val[9:]
                elif val.startswith("STRING: "):
                    s = val[8:]
                    # Strip quotes if present
                    if s.startswith('"') and s.endswith('"'):
                        s = s[1:-1]
                    return s
                elif val.startswith("Gauge32: "):
                    return val[9:]
                else:
                    # Try plain number
                    return val.strip()

            idx = parse_value(lines[i])
            stype = parse_value(lines[i+1])
            desc = parse_value(lines[i+2])
            value = parse_value(lines[i+3])
            min_th = parse_value(lines[i+4])
            max_th = parse_value(lines[i+5])

            # Skip unparseable entries
            if idx == None or stype == None or desc == None or value == None:
                i += 6
                continue

            # Convert numeric values - guard instead of try/except
            value_f = 0.0
            if value != None and (value.isdigit() or (value and value.replace('.','').replace('-','').isdigit())):
                value_f = float(value)
            else:
                i += 6
                continue

            min_f = None
            max_f = None
            if min_th != None and (min_th.isdigit() or (min_th and min_th.replace('.','').replace('-','').isdigit())):
                min_f = float(min_th)
            if max_th != None and (max_th.isdigit() or (max_th and max_th.replace('.','').replace('-','').isdigit())):
                max_f = float(max_th)

            # Apply scaling for temperature/power/current
            sensor_type = SENSOR_TYPE_NAMES.get(str(stype), "unknown")
            if sensor_type in ["temperature", "power", "current", "temperatureCombo"]:
                value_f /= 10.0
                if min_f != None:
                    min_f /= 10.0
                if max_f != None:
                    max_f /= 10.0

            # Build item name: "<description> <index>"
            item_name = desc + " " + idx
            data[item_name] = {
                "type": sensor_type,
                "value": value_f,
                "min_threshold": min_f,
                "max_threshold": max_f,
            }
            i += 6

        # Build discovery result for temperature/humidity/voltage
        discovery = []
        for item, sensor in data.items():
            sensor_type = sensor.get("type", "")
            if sensor_type in ["temperature", "temperatureCombo"]:
                # Temperature service: no special params beyond default temperature levels
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": ["temp"]
                })
            elif sensor_type == "humidity":
                # Humidity service: default humidity params
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": ["humidity"]
                })
            elif sensor_type == "power":
                # Voltage service: default voltage params
                discovery.append({
                    "item": item,
                    "params": ENVIROMUX_CHECK_DEFAULT_PARAMETERS,
                    "metrics": ["voltage"]
                })

        return {"changed": False, "msg": "discovered %d sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")
    # Re-fetch data (same as discovery, but for single item)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1",
        base_oid + ".2",
        base_oid + ".3",
        base_oid + ".7",
        base_oid + ".11",
        base_oid + ".12",
    ], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse output to find the item
    lines = res.stdout.splitlines()
    sensor = None
    i = 0
    while i + 5 < len(lines):
        # Extract index, type, description, value, min, max
        def parse_value(line):
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                return None
            val = parts[1]
            if val.startswith("INTEGER: "):
                return val[9:]
            elif val.startswith("STRING: "):
                s = val[8:]
                if s.startswith('"') and s.endswith('"'):
                    s = s[1:-1]
                return s
            elif val.startswith("Gauge32: "):
                return val[9:]
            else:
                return val.strip()

        idx = parse_value(lines[i])
        stype = parse_value(lines[i+1])
        desc = parse_value(lines[i+2])
        value = parse_value(lines[i+3])
        min_th = parse_value(lines[i+4])
        max_th = parse_value(lines[i+5])

        if idx == None or stype == None or desc == None or value == None:
            i += 6
            continue

        # Convert numeric values - guard instead of try/except
        value_f = 0.0
        if value != None and (value.isdigit() or (value and value.replace('.','').replace('-','').isdigit())):
            value_f = float(value)
        else:
            i += 6
            continue

        min_f = None
        max_f = None
        if min_th != None and (min_th.isdigit() or (min_th and min_th.replace('.','').replace('-','').isdigit())):
            min_f = float(min_th)
        if max_th != None and (max_th.isdigit() or (max_th and max_th.replace('.','').replace('-','').isdigit())):
            max_f = float(max_th)

        sensor_type = SENSOR_TYPE_NAMES.get(str(stype), "unknown")
        if sensor_type in ["temperature", "power", "current", "temperatureCombo"]:
            value_f /= 10.0
            if min_f != None:
                min_f /= 10.0
            if max_f != None:
                max_f /= 10.0

        # Check if item matches
        if (desc + " " + idx) == item:
            sensor = {
                "type": sensor_type,
                "value": value_f,
                "min_threshold": min_f,
                "max_threshold": max_f,
            }
            break

        i += 6

    # Item not found
    if sensor == None:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_type = sensor.get("type", "")
    value = sensor["value"]

    # Determine state and message based on sensor type
    if sensor_type in ["temperature", "temperatureCombo"]:
        # Temperature check: use standard temperature levels
        warn = params.get("levels", [25.0, 30.0])
        warn_upper = warn[0]
        crit_upper = warn[1]
        warn_lower = params.get("levels_lower", [10.0, 5.0])
        warn_lower_upper = warn_lower[0]
        crit_lower_upper = warn_lower[1]

        state = "OK"
        if sensor["max_threshold"] != None and sensor["max_threshold"] > 0:
            max_t = sensor["max_threshold"]
            if value >= max_t:
                state = "CRIT"
            elif value >= max_t * 0.95:  # Approximate Checkmk behavior
                state = "WARN"

        if sensor["min_threshold"] != None and sensor["min_threshold"] > 0:
            min_t = sensor["min_threshold"]
            if value <= min_t:
                state = "CRIT"
            elif state == "OK" and value <= min_t * 1.05:  # Approximate Checkmk behavior
                state = "WARN"

        # Fallback to param-based levels if thresholds not available
        if state == "OK":
            if value >= crit_upper:
                state = "CRIT"
            elif value >= warn_upper:
                state = "WARN"

        if state == "OK" and sensor["min_threshold"] == None:
            if value <= crit_lower_upper:
                state = "CRIT"
            elif value <= warn_lower_upper:
                state = "WARN"

        # Build message
        msg = "Temperature: %f C" % value
        if sensor["min_threshold"] != None and sensor["min_threshold"] > 0:
            msg += " (min threshold: %f C)" % sensor["min_threshold"]
        if sensor["max_threshold"] != None and sensor["max_threshold"] > 0:
            msg += " (max threshold: %f C)" % sensor["max_threshold"]

        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {"temp": value}, "details": ""}}

    elif sensor_type == "humidity":
        # Humidity check
        warn = params.get("levels_lower", [30.0, 20.0])
        warn_upper = warn[0]
        crit_upper = warn[1]
        warn_lower = params.get("levels", [80.0, 90.0])
        warn_lower_upper = warn_lower[0]
        crit_lower_upper = warn_lower[1]

        state = "OK"
        if value >= crit_lower_upper:
            state = "CRIT"
        elif value >= warn_lower_upper:
            state = "WARN"
        elif value <= crit_upper:
            state = "CRIT"
        elif value <= warn_upper:
            state = "WARN"

        msg = "Humidity: %f%%" % value
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {"humidity": value}, "details": ""}}

    elif sensor_type == "power":
        # Voltage check
        levels_upper = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])
        levels_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])

        state = "OK"
        if value >= levels_upper[1]:
            state = "CRIT"
        elif value >= levels_upper[0]:
            state = "WARN"
        elif value <= levels_lower[1]:
            state = "CRIT"
        elif value <= levels_lower[0]:
            state = "WARN"

        msg = "Voltage: %f V" % value
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {"voltage": value}, "details": ""}}

    else:
        # Unsupported sensor type
        return {"changed": False, "msg": "Unsupported sensor type: " + sensor_type,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
