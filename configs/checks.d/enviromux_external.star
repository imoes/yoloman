def main(ctx, params):
    # Common SNMP OIDs and base for Enviromux
    base_oid_enviromux = ".1.3.6.1.4.1.3699.1.1.11.1.5.1.1"
    base_oid_enviromux5 = ".1.3.6.1.4.1.3699.1.1.10.1.5.1.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Sensor type mapping (from Checkmk source)
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

    # Helper to walk an OID and parse the results
    def walk_and_parse(base_oid):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            return None
        lines = res.stdout.splitlines()
        result = []
        for line in lines:
            # Format: OID = TYPE: VALUE
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            value_part = line[eq_idx + 1:].strip()
            # Extract last number from OID for index mapping
            oid_nums = oid_part.split(".")
            if len(oid_nums) < 1:
                continue
            idx_str = oid_nums[-1]
            # Parse value (TYPE: VALUE)
            colon_idx = value_part.find(":")
            if colon_idx == -1:
                value = value_part.strip()
            else:
                value = value_part[colon_idx + 1:].strip()
            result.append((idx_str, value))
        return result

    # Discovery mode: enumerate items with sensor data
    if params.get("_discover"):
        # Try enviromux5 base first, fall back to enviromux
        data = walk_and_parse(base_oid_enviromux5)
        if data == None:
            data = walk_and_parse(base_oid_enviromux)
        if data == None:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        # Group data by index (1-6 OIDs per index)
        # oid1=1 (index), oid2=2 (type), oid3=3 (description), oid7=7 (value), oid11=11 (min), oid12=12 (max)
        # We need to reorganize by index
        by_index = {}
        for i, (idx, value) in enumerate(data):
            # oid position: 1,2,3,7,11,12 -> positions 0,1,2,3,4,5
            # Each index has 6 entries
            pos = i % 6
            if idx not in by_index:
                by_index[idx] = [None] * 6
            by_index[idx][pos] = value

        discovered = []
        for idx, values in by_index.items():
            if len(values) < 6 or values[0] == None:
                continue
            # values[0] = extSensorIndex, values[1] = extSensorType, values[2] = extSensorDescription
            # values[3] = extSensorValue, values[4] = extSensorMinThreshold, values[5] = extSensorMaxThreshold
            sensor_type = SENSOR_TYPE_NAMES.get(values[1], "unknown")
            if sensor_type not in ["temperature", "humidity", "power"]:
                continue
            sensor_name = values[2] + " " + values[0]
            params_item = {}
            if sensor_type == "temperature":
                params_item = {"levels": (15.0, 16.0), "levels_lower": (10.0, 9.0)}
            elif sensor_type == "power":
                params_item = {"levels": (15.0, 16.0), "levels_lower": (10.0, 9.0)}
            elif sensor_type == "humidity":
                params_item = {}
            discovered.append({
                "item": sensor_name,
                "params": params_item,
                "metrics": ["temperature", "humidity", "voltage"] if sensor_type in ["temperature", "humidity", "power"] else []
            })

        return {"changed": False, "msg": "discovered %d items" % len(discovered), "data": {"discovery": discovered}}

    # Check mode: process one item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Fetch raw SNMP data
    data = walk_and_parse(base_oid_enviromux5)
    if data == None:
        data = walk_and_parse(base_oid_enviromux)
    if data == None:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Reorganize by index
    by_index = {}
    for i, (idx, value) in enumerate(data):
        pos = i % 6
        if idx not in by_index:
            by_index[idx] = [None] * 6
        by_index[idx][pos] = value

    # Find the matching sensor
    sensor_value = None
    sensor_type = None
    sensor_min = None
    sensor_max = None

    for idx, values in by_index.items():
        if len(values) < 6 or values[0] == None:
            continue
        sensor_name = values[2] + " " + values[0]
        if sensor_name == item:
            sensor_type = SENSOR_TYPE_NAMES.get(values[1], "unknown")
            sensor_value = float(values[3]) if values[3].isdigit() or values[3].replace('.', '').isdigit() else None
            # Only scale if type indicates so
            if sensor_value != None and sensor_type in ["temperature", "power", "current", "temperatureCombo"]:
                sensor_value = float(values[3]) / 10.0
            if sensor_value != None:
                sensor_value = float(values[3]) if values[3].isdigit() or values[3].replace('.', '').isdigit() else None
                if sensor_type in ["temperature", "power", "current", "temperatureCombo"]:
                    sensor_value = float(values[3]) / 10.0
            # Handle thresholds
            sensor_min = None
            sensor_max = None
            if values[4] != None and values[4] != "Not configured" and (values[4].isdigit() or values[4].replace('.', '').isdigit()):
                sensor_min = float(values[4]) / 10.0 if sensor_type in ["temperature", "power", "current", "temperatureCombo"] else float(values[4])
            if values[5] != None and values[5] != "Not configured" and (values[5].isdigit() or values[5].replace('.', '').isdigit()):
                sensor_max = float(values[5]) / 10.0 if sensor_type in ["temperature", "power", "current", "temperatureCombo"] else float(values[5])
            break

    if sensor_value == None:
        return {"changed": False, "msg": "sensor not found or invalid value", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Determine state based on sensor type and thresholds
    warn = params.get("warn")
    crit = params.get("crit")
    warn_lower = params.get("warn_lower")
    crit_lower = params.get("crit_lower")

    # Use Checkmk defaults for temperature
    if sensor_type in ["temperature", "temperatureCombo"]:
        warn = warn if warn != None else 15.0
        crit = crit if crit != None else 16.0
        warn_lower = warn_lower if warn_lower != None else 10.0
        crit_lower = crit_lower if crit_lower != None else 9.0
    # Use Checkmk defaults for voltage (power type in Checkmk source)
    elif sensor_type == "power":
        warn = warn if warn != None else 15.0
        crit = crit if crit != None else 16.0
        warn_lower = warn_lower if warn_lower != None else 10.0
        crit_lower = crit_lower if crit_lower != None else 9.0
    # Humidity defaults (from check_humidity)
    elif sensor_type in ["humidity", "humidityCombo"]:
        warn = warn if warn != None else 70.0
        crit = crit if crit != None else 80.0
        warn_lower = warn_lower if warn_lower != None else 30.0
        crit_lower = crit_lower if crit_lower != None else 20.0

    # Apply thresholds
    state = "OK"
    msg_parts = []

    if sensor_type in ["temperature", "temperatureCombo"]:
        msg_parts.append("Temperature: %f" % sensor_value)
        if sensor_max != None and sensor_value >= sensor_max:
            state = "CRIT"
        elif sensor_min != None and sensor_value <= sensor_min:
            state = "CRIT"
        elif sensor_value >= crit:
            state = "CRIT"
        elif sensor_value <= crit_lower:
            state = "CRIT"
        elif sensor_value >= warn:
            state = "WARN"
        elif sensor_value <= warn_lower:
            state = "WARN"
    elif sensor_type == "power":
        # voltage type
        msg_parts.append("Voltage: %f" % sensor_value)
        if sensor_max != None and sensor_value >= sensor_max:
            state = "CRIT"
        elif sensor_min != None and sensor_value <= sensor_min:
            state = "CRIT"
        elif sensor_value >= crit:
            state = "CRIT"
        elif sensor_value <= crit_lower:
            state = "CRIT"
        elif sensor_value >= warn:
            state = "WARN"
        elif sensor_value <= warn_lower:
            state = "WARN"
    elif sensor_type in ["humidity", "humidityCombo"]:
        msg_parts.append("Humidity: %f" % sensor_value)
        if sensor_value >= crit:
            state = "CRIT"
        elif sensor_value <= crit_lower:
            state = "CRIT"
        elif sensor_value >= warn:
            state = "WARN"
        elif sensor_value <= warn_lower:
            state = "WARN"

    metrics = {}
    if sensor_type in ["temperature", "temperatureCombo"]:
        metrics["temperature"] = sensor_value
    elif sensor_type == "power":
        metrics["voltage"] = sensor_value
    elif sensor_type in ["humidity", "humidityCombo"]:
        metrics["humidity"] = sensor_value

    msg = ", ".join(msg_parts) + ", State: " + state
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": ""}}
