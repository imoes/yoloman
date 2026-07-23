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

def _parse_enviromux(string_table):
    """Parse enviromux sensor data from SNMP string table"""
    sensors = {}
    for line in string_table:
        if len(line) < 6:
            continue
        sensor_index = line[0]
        sensor_type = line[1]
        sensor_description = line[2]
        sensor_value_str = line[3]
        sensor_min_str = line[4]
        sensor_max_str = line[5]
        
        # Guard instead of try/except - only process if all string fields are numeric
        if not sensor_value_str.isdigit() or not sensor_min_str.isdigit() or not sensor_max_str.isdigit():
            continue
        
        sensor_value = int(sensor_value_str)
        sensor_min = int(sensor_min_str)
        sensor_max = int(sensor_max_str)
        
        sensor_name = sensor_description + " " + sensor_index
        type_name = SENSOR_TYPE_NAMES.get(sensor_type, "unknown")
        
        # Apply scaling factor 10 for certain sensor types
        if type_name in ["temperature", "power", "current", "temperatureCombo"]:
            sensor_value = sensor_value / 10.0
            sensor_min = sensor_min / 10.0
            sensor_max = sensor_max / 10.0
        
        sensors[sensor_name] = {
            "type": type_name,
            "value": sensor_value,
            "min_threshold": sensor_min,
            "max_threshold": sensor_max,
        }
    return sensors

def _check_temperature(reading, params, dev_levels_lower=None, dev_levels=None):
    """Check temperature against levels"""
    # Extract thresholds from params
    levels_upper = params.get("levels", (None, None))
    levels_lower = params.get("levels_lower", (None, None))
    
    # Use device thresholds if not in params
    if dev_levels != None and levels_upper == (None, None):
        levels_upper = (dev_levels[0], dev_levels[1])
    if dev_levels_lower != None and levels_lower == (None, None):
        levels_lower = (dev_levels_lower[0], dev_levels_lower[1])
    
    warn_upper, crit_upper = levels_upper
    warn_lower, crit_lower = levels_lower
    
    # Check upper levels
    if crit_upper != None and reading >= crit_upper:
        return ("CRIT", "Temperature is %f (warn at %f, crit at %f)" % (reading, warn_upper if warn_upper != None else 0, crit_upper))
    if warn_upper != None and reading >= warn_upper:
        return ("WARN", "Temperature is %f (warn at %f, crit at %f)" % (reading, warn_upper, crit_upper if crit_upper != None else 0))
    
    # Check lower levels
    if crit_lower != None and reading <= crit_lower:
        return ("CRIT", "Temperature is %f (warn below %f, crit below %f)" % (reading, warn_lower if warn_lower != None else 0, crit_lower))
    if warn_lower != None and reading <= warn_lower:
        return ("WARN", "Temperature is %f (warn below %f, crit below %f)" % (reading, warn_lower, crit_lower if crit_lower != None else 0))
    
    return ("OK", "Temperature is %f" % reading)

def _check_voltage(value, params):
    """Check voltage against levels"""
    levels_upper = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])
    levels_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])
    
    warn_upper, crit_upper = levels_upper[0], levels_upper[1]
    warn_lower, crit_lower = levels_lower[0], levels_lower[1]
    
    if crit_upper != None and value >= crit_upper:
        return ("CRIT", "Voltage is %f V (warn at %f, crit at %f)" % (value, warn_upper, crit_upper))
    if warn_upper != None and value >= warn_upper:
        return ("WARN", "Voltage is %f V (warn at %f, crit at %f)" % (value, warn_upper, crit_upper))
    
    if crit_lower != None and value <= crit_lower:
        return ("CRIT", "Voltage is %f V (warn below %f, crit below %f)" % (value, warn_lower, crit_lower))
    if warn_lower != None and value <= warn_lower:
        return ("WARN", "Voltage is %f V (warn below %f, crit below %f)" % (value, warn_lower, crit_lower))
    
    return ("OK", "Voltage is %f V" % value)

def _check_humidity(humidity, params):
    """Check humidity against levels"""
    # Checkmk humidity check uses relative humidity thresholds
    levels_upper = params.get("levels", (None, None))
    levels_lower = params.get("levels_lower", (None, None))
    
    warn_upper, crit_upper = levels_upper
    warn_lower, crit_lower = levels_lower
    
    if crit_upper != None and humidity >= crit_upper:
        return ("CRIT", "Humidity is %f%% (warn at %f%%, crit at %f%%)" % (humidity, warn_upper if warn_upper != None else 0, crit_upper))
    if warn_upper != None and humidity >= warn_upper:
        return ("WARN", "Humidity is %f%% (warn at %f%%, crit at %f%%)" % (humidity, warn_upper, crit_upper if crit_upper != None else 0))
    
    if crit_lower != None and humidity <= crit_lower:
        return ("CRIT", "Humidity is %f%% (warn below %f%%, crit below %f%%)" % (humidity, warn_lower if warn_lower != None else 0, crit_lower))
    if warn_lower != None and humidity <= warn_lower:
        return ("WARN", "Humidity is %f%% (warn below %f%%, crit below %f%%)" % (humidity, warn_lower, crit_lower if crit_lower != None else 0))
    
    return ("OK", "Humidity is %f%%" % humidity)

def main(ctx, params):
    # Get SNMP parameters
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Determine which section to use based on detection
    # Check for Enviromux5 (base OID .1.3.6.1.4.1.3699.1.1.10) first
    # then Enviromux (base OID .1.3.6.1.4.1.3699.1.1.11)
    base_oid = ".1.3.6.1.4.1.3699.1.1.11.1.3.1.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    system_oid = res.stdout.strip().split(" = ")[-1].strip() if res.stdout else ""
    
    # Check for Enviromux5
    if system_oid.startswith(".1.3.6.1.4.1.3699.1.1.10"):
        base_oid = ".1.3.6.1.4.1.3699.1.1.10.1.3.1.1"
    
    # Walk the enviromux sensor table
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1",  # intSensorIndex
        base_oid + ".2",  # intSensorType
        base_oid + ".3",  # intSensorDescription
        base_oid + ".6",  # intSensorValue
        base_oid + ".10", # intSensorMinThreshold
        base_oid + ".11", # intSensorMaxThreshold
    ], mutates=False)
    
    # Parse SNMP output - format: "OID = TYPE: value"
    lines = res.stdout.splitlines() if res.stdout else []
    
    # Organize lines by sensor index (each sensor has 6 lines)
    # We'll parse this differently: collect all lines and group them
    sensor_data = []
    current_sensor = []
    
    for line in lines:
        # Parse OID = TYPE: value
        if " = " in line:
            parts = line.split(" = ", 1)
            value_str = parts[1].strip()
            # Extract just the value (remove type prefix like "INTEGER: " or "Gauge32: ")
            if ": " in value_str:
                value = value_str.split(": ", 1)[1].strip()
            else:
                value = value_str
            current_sensor.append(value)
            
            # Every 6 lines belong to one sensor
            if len(current_sensor) == 6:
                sensor_data.append(current_sensor)
                current_sensor = []
    
    # Parse the sensor data
    section = _parse_enviromux(sensor_data)
    
    if params.get("_discover"):
        # Discovery mode
        items = []
        for item, sensor in section.items():
            sensor_type = sensor.get("type", "")
            if sensor_type in ["temperature", "temperatureCombo"]:
                items.append({
                    "item": item,
                    "params": params.get("temperature", {}),
                    "metrics": ["temp"]
                })
            elif sensor_type == "power":
                items.append({
                    "item": item,
                    "params": params.get("voltage", ENVIROMUX_CHECK_DEFAULT_PARAMETERS),
                    "metrics": ["voltage"]
                })
            elif sensor_type in ["humidity", "humidityCombo"]:
                items.append({
                    "item": item,
                    "params": params.get("humidity", {}),
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    sensor = section.get(item)
    
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    sensor_type = sensor.get("type", "")
    
    # Get thresholds from params or use defaults
    if sensor_type in ["temperature", "temperatureCombo"]:
        state, msg = _check_temperature(
            sensor["value"],
            params,
            dev_levels_lower=(sensor.get("min_threshold"), sensor.get("min_threshold")) if sensor.get("min_threshold") != None else None,
            dev_levels=(sensor.get("max_threshold"), sensor.get("max_threshold")) if sensor.get("max_threshold") != None else None
        )
        metrics = {"temp": sensor["value"]}
    elif sensor_type == "power":
        state, msg = _check_voltage(
            sensor["value"],
            params if params != None else ENVIROMUX_CHECK_DEFAULT_PARAMETERS
        )
        metrics = {"voltage": sensor["value"]}
    elif sensor_type in ["humidity", "humidityCombo"]:
        state, msg = _check_humidity(sensor["value"], params if params != None else {})
        metrics = {"humidity": sensor["value"]}
    else:
        state = "UNKNOWN"
        msg = "unknown sensor type: " + sensor_type
        metrics = {}
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
