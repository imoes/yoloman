# Helper constants
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
    "levels": (15.0, 16.0),
    "levels_lower": (10.0, 9.0),
}


def _parse_enviromux_section(stdout):
    section = {}
    lines = stdout.splitlines()
    for line in lines:
        parts = line.split("|")
        if len(parts) < 6:
            continue
        sensor_index = parts[0]
        sensor_type = parts[1]
        sensor_desc = parts[2]
        sensor_value = parts[3]
        sensor_min = parts[4]
        sensor_max = parts[5]

        # Skip if value cannot be converted to float (guard instead of try)
        if not sensor_value.replace(".", "").replace("-", "").isdigit():
            continue
        if not sensor_min.replace(".", "").replace("-", "").isdigit():
            continue
        if not sensor_max.replace(".", "").replace("-", "").isdigit():
            continue
            
        value = float(sensor_value)
        min_val = float(sensor_min)
        max_val = float(sensor_max)

        sensor_name = sensor_desc + " " + sensor_index
        type_name = SENSOR_TYPE_NAMES.get(sensor_type, "unknown")
        
        # Scaling for temperature, power, current, temperatureCombo
        if type_name in ["temperature", "power", "current", "temperatureCombo"]:
            value /= 10.0
            min_val /= 10.0
            max_val /= 10.0

        section[sensor_name] = {
            "type": type_name,
            "value": value,
            "min_threshold": min_val,
            "max_threshold": max_val,
        }
    return section


def _check_humidity_level(humidity, params):
    # params may contain "levels" (upper) and "levels_lower" (lower)
    levels = params.get("levels", (15.0, 16.0))
    levels_lower = params.get("levels_lower", (10.0, 9.0))
    
    upper_warn, upper_crit = levels
    lower_warn, lower_crit = levels_lower
    
    if humidity >= upper_crit:
        return "CRIT", "Humidity %d%% (warn at %d%%, crit at %d%%)" % (humidity, upper_warn, upper_crit)
    elif humidity >= upper_warn:
        return "WARN", "Humidity %d%% (warn at %d%%, crit at %d%%)" % (humidity, upper_warn, upper_crit)
    elif humidity <= lower_crit:
        return "CRIT", "Humidity %d%% (lower crit at %d%%)" % (humidity, lower_crit)
    elif humidity <= lower_warn:
        return "WARN", "Humidity %d%% (lower warn at %d%%)" % (humidity, lower_warn)
    else:
        return "OK", "Humidity %d%%" % humidity


def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.3699.1.1.2.1.4.1.1"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Discovery mode: get all sensors and enumerate humidity sensors
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".2",  # intSensorType
            base_oid + ".3",  # intSensorDescription
            base_oid + ".6",  # intSensorValue
        ], mutates=False)

        # Parse snmpwalk output: OID = TYPE: VALUE
        lines = res.stdout.splitlines()
        sensors = {}
        
        # Process line by line, keeping track of which OID we're processing
        current_index = None
        current_type = None
        current_desc = None
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
            # Split into OID and value parts
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid, value_part = parts
            
            # Extract value after type prefix
            if ": " in value_part:
                value = value_part.split(": ", 1)[1].strip()
            else:
                value = value_part.strip()
            
            # Check which field this is by OID suffix
            if oid.endswith(".2"):
                # Sensor type
                current_index = oid.rsplit(".", 1)[1]
                current_type = value
            elif oid.endswith(".3"):
                # Sensor description
                sensor_idx = oid.rsplit(".", 1)[1]
                if sensor_idx == current_index and current_type != None:
                    sensors[sensor_idx] = {
                        "type": current_type,
                        "desc": value,
                    }
            elif oid.endswith(".6"):
                # Sensor value
                sensor_idx = oid.rsplit(".", 1)[1]
                if sensor_idx == current_index:
                    sensors[sensor_idx]["value"] = value

        discovery_list = []
        for idx, sensor in sensors.items():
            type_name = SENSOR_TYPE_NAMES.get(sensor.get("type", "0"), "unknown")
            if type_name in ["humidity", "humidityCombo"]:
                sensor_name = sensor.get("desc", "") + " " + idx
                discovery_list.append({
                    "item": sensor_name,
                    "params": ENVIROMUX_CHECK_DEFAULT_PARAMETERS,
                    "metrics": ["humidity"],
                })
        return {"changed": False, "msg": "discovered %d humidity sensors" % len(discovery_list),
                "data": {"discovery": discovery_list}}

    # Check mode: verify one item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item provided",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather humidity sensor data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".2",  # intSensorType
        base_oid + ".3",  # intSensorDescription
        base_oid + ".6",  # intSensorValue
    ], mutates=False)

    # Parse snmpwalk output
    lines = res.stdout.splitlines()
    sensors = {}
    current_index = None
    current_type = None
    current_desc = None

    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid, value_part = parts
        if ": " in value_part:
            value = value_part.split(": ", 1)[1].strip()
        else:
            value = value_part.strip()

        if oid.endswith(".2"):
            current_index = oid.rsplit(".", 1)[1]
            current_type = value
        elif oid.endswith(".3"):
            sensor_idx = oid.rsplit(".", 1)[1]
            if sensor_idx == current_index:
                sensors[sensor_idx] = {
                    "type": current_type,
                    "desc": value,
                }
        elif oid.endswith(".6"):
            sensor_idx = oid.rsplit(".", 1)[1]
            if sensor_idx == current_index:
                sensors[sensor_idx]["value"] = value

    # Find the target sensor by name
    humidity_value = None
    for idx, sensor in sensors.items():
        type_name = SENSOR_TYPE_NAMES.get(sensor.get("type", "0"), "unknown")
        if type_name in ["humidity", "humidityCombo"]:
            sensor_name = sensor.get("desc", "") + " " + idx
            if sensor_name == item:
                val_str = sensor.get("value", "0")
                if val_str.isdigit() or (val_str.replace(".", "").replace("-", "").isdigit() and val_str.count(".") <= 1):
                    humidity_value = float(val_str)
                break

    if humidity_value == None:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Determine thresholds from params or defaults
    levels = params.get("levels", (15.0, 16.0))
    levels_lower = params.get("levels_lower", (10.0, 9.0))

    # Check humidity levels
    # Use manual rounding: int(x + 0.5) for positive numbers
    rounded_humidity = int(humidity_value + 0.5) if humidity_value >= 0 else int(humidity_value - 0.5)
    state, msg = _check_humidity_level(rounded_humidity, params)

    # Format message for checkmk-style output
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"humidity": humidity_value}, "details": ""}}
