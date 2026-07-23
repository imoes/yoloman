# Constants for sensor types and names (defined at module top level)
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

# Helper to parse sensor data from SNMP table
def parse_enviromux(string_table):
    enviromux_sensors = {}
    for line in string_table:
        if len(line) < 6:
            continue
        
        # Validate and convert to float
        def to_float(s):
            s = str(s).strip()
            if s == "Not configured" or s == "":
                return None
            # Simple validation: only digits, minus, dot, e/E allowed
            valid_chars = "0123456789.-eE+"
            for c in s:
                if not (c in valid_chars):
                    return None
            # No try/except: we validated first, so this will succeed
            return float(s)
        
        v1 = line[3]
        v2 = line[4]
        v3 = line[5]
        
        sensor_value = to_float(v1)
        sensor_min = to_float(v2)
        sensor_max = to_float(v3)
        
        # Skip if any value failed to convert
        if sensor_value == None or sensor_min == None or sensor_max == None:
            continue
        
        sensor_name = str(line[2]) + " " + str(line[0])
        sensor_type = SENSOR_TYPE_NAMES.get(str(line[1]), "unknown")
        
        # Scaling factor 10 for temperature, power, current, and temperatureCombo
        if sensor_type in ["temperature", "power", "current", "temperatureCombo"]:
            sensor_value = sensor_value / 10.0
            sensor_min = sensor_min / 10.0
            sensor_max = sensor_max / 10.0
        
        enviromux_sensors[sensor_name] = {
            "type": sensor_type,
            "value": sensor_value,
            "min_threshold": sensor_min,
            "max_threshold": sensor_max,
        }
    return enviromux_sensors


# Helper to run snmpget and extract value
def snmp_get_value(ctx, host, community, oid):
    res = ctx.run([
        "snmpget",
        "-v2c",
        "-c",
        community,
        "-On",
        host,
        oid
    ], mutates=False)
    if res.rc != 0:
        return None
    line = res.stdout.strip()
    if line.find(" = ") == -1:
        return None
    parts = line.split(" = ")
    if len(parts) < 2:
        return None
    value = parts[1].strip()
    if value.find(": ") != -1:
        value = value.split(": ", 1)[1].strip()
    return value


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        # Get sensor indices by walking index OID
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c",
            community,
            "-On",
            host,
            ".1.3.6.1.4.1.3699.1.1.9.1.5.1.1.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        # Parse sensor indices from the walk
        lines = res.stdout.splitlines()
        indices = []
        for line in lines:
            parts = line.split(" = ")
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            idx = oid.rsplit(".", 1)[-1]
            # Validate index is numeric
            is_valid = True
            for c in idx:
                if not (c >= "0" and c <= "9"):
                    is_valid = False
                    break
            if is_valid:
                indices.append(int(idx))
        
        # For each index, get all 6 values
        string_table = []
        for idx in indices:
            values = []
            for oid_num in ["1", "2", "3", "7", "11", "12"]:
                val = snmp_get_value(ctx, host, community, ".1.3.6.1.4.1.3699.1.1.9.1.5.1.1." + oid_num + "." + str(idx))
                if val != None:
                    values.append(val)
            
            # We need exactly 6 values
            if len(values) == 6:
                string_table.append(values)
        
        # Parse and discover
        section = parse_enviromux(string_table)
        discovery = []
        
        for item, sensor in section.items():
            if sensor["type"] in ["temperature", "temperatureCombo"]:
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": ["temperature"]
                })
            elif sensor["type"] == "power":
                discovery.append({
                    "item": item,
                    "params": ENVIROMUX_CHECK_DEFAULT_PARAMETERS,
                    "metrics": ["voltage"]
                })
            elif sensor["type"] in ["humidity", "humidityCombo"]:
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": ["humidity"]
                })
        
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode (normal path)
    item = params.get("item", "")
    
    # Get sensor indices by walking index OID
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c",
        community,
        "-On",
        host,
        ".1.3.6.1.4.1.3699.1.1.9.1.5.1.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP error: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse sensor indices from the walk
    lines = res.stdout.splitlines()
    indices = []
    for line in lines:
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        oid = parts[0].strip()
        idx = oid.rsplit(".", 1)[-1]
        is_valid = True
        for c in idx:
            if not (c >= "0" and c <= "9"):
                is_valid = False
                break
        if is_valid:
            indices.append(int(idx))
    
    # Build string table
    string_table = []
    for idx in indices:
        values = []
        for oid_num in ["1", "2", "3", "7", "11", "12"]:
            val = snmp_get_value(ctx, host, community, ".1.3.6.1.4.1.3699.1.1.9.1.5.1.1." + oid_num + "." + str(idx))
            if val != None:
                values.append(val)
        if len(values) == 6:
            string_table.append(values)
    
    # Parse section
    section = parse_enviromux(string_table)
    
    # Check if item exists
    sensor = section.get(item)
    if sensor == None:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply thresholds based on sensor type
    sensor_type = sensor["type"]
    value = sensor["value"]
    min_threshold = sensor["min_threshold"]
    max_threshold = sensor["max_threshold"]
    
    state = "OK"
    msg_parts = []
    metrics = {}
    
    if sensor_type in ["temperature", "temperatureCombo"]:
        # Temperature check
        params_levels = params.get("levels", (20.0, 25.0))
        warn_upper = params_levels[0] if len(params_levels) > 0 else 20.0
        crit_upper = params_levels[1] if len(params_levels) > 1 else 25.0
        warn_lower = params.get("levels_lower", None)
        crit_lower = warn_lower
        if warn_lower != None:
            warn_lower = warn_lower[0] if len(warn_lower) > 0 else 15.0
            crit_lower = crit_lower[1] if len(crit_lower) > 1 else 10.0
        
        # Check upper levels
        if crit_upper != None and value >= crit_upper:
            state = "CRIT"
        elif warn_upper != None and value >= warn_upper:
            state = "WARN" if state == "OK" else state
        
        # Check lower levels
        if crit_lower != None and value <= crit_lower:
            state = "CRIT"
        elif warn_lower != None and value <= warn_lower:
            state = "WARN" if state == "OK" else state
        
        # Deviation thresholds from device
        if min_threshold != None and value <= min_threshold:
            state = "CRIT" if state != "CRIT" else state
            msg_parts.append("min_threshold=%f" % min_threshold)
        if max_threshold != None and value >= max_threshold:
            state = "CRIT" if state != "CRIT" else state
            msg_parts.append("max_threshold=%f" % max_threshold)
        
        metrics["temperature"] = value
        msg_parts.insert(0, "Temperature: %f C" % value)
    
    elif sensor_type == "power":
        # Voltage check
        params_levels = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])
        params_levels_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])
        
        warn_upper = params_levels[0] if len(params_levels) > 0 else 15.0
        crit_upper = params_levels[1] if len(params_levels) > 1 else 16.0
        warn_lower = params_levels_lower[0] if len(params_levels_lower) > 0 else 10.0
        crit_lower = params_levels_lower[1] if len(params_levels_lower) > 1 else 9.0
        
        # Check upper levels
        if crit_upper != None and value >= crit_upper:
            state = "CRIT"
        elif warn_upper != None and value >= warn_upper:
            state = "WARN" if state == "OK" else state
        
        # Check lower levels
        if crit_lower != None and value <= crit_lower:
            state = "CRIT"
        elif warn_lower != None and value <= warn_lower:
            state = "WARN" if state == "OK" else state
        
        metrics["voltage"] = value
        msg_parts.append("Voltage: %f V" % value)
    
    elif sensor_type in ["humidity", "humidityCombo"]:
        # Humidity check - use standard humidity levels
        params_levels = params.get("levels", (60.0, 80.0))
        warn_upper = params_levels[0] if len(params_levels) > 0 else 60.0
        crit_upper = params_levels[1] if len(params_levels) > 1 else 80.0
        
        # Check upper levels
        if crit_upper != None and value >= crit_upper:
            state = "CRIT"
        elif warn_upper != None and value >= warn_upper:
            state = "WARN" if state == "OK" else state
        
        metrics["humidity"] = value
        msg_parts.append("Humidity: %f %%" % value)
    
    msg = ", ".join(msg_parts) if msg_parts else "Sensor: " + str(value)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}