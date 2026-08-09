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

DETECT_ENVIROMUX_MICRO_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_ENVIROMUX_MICRO_VALUE = ".1.3.6.1.4.1.3699.1.1.12"

ENVIROMUX_CHECK_DEFAULT_PARAMETERS = {
    "levels": (15.0, 16.0),
    "levels_lower": (10.0, 9.0),
}


def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.3699.1.1.12.1.1.1.1"
    
    if params.get("_discover"):
        # Discover humidity sensors only
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), base_oid
        ], mutates=False)
        
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        sensors = {}
        current_index = ""
        current_type = ""
        current_desc = ""
        current_value = ""
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            
            oid_part = parts[0]
            value_part = parts[1]
            
            # Extract OID suffix
            suffix = oid_part.rsplit(".", 1)[-1]
            
            if oid_part.endswith(".1"):
                current_index = value_part.strip()
                current_desc = ""
                current_type = ""
                current_value = ""
            elif oid_part.endswith(".2"):
                current_type = value_part.split(": ", 1)[-1].strip()
            elif oid_part.endswith(".3"):
                current_desc = value_part.split(": ", 1)[-1].strip()
            elif oid_part.endswith(".4"):
                current_value = value_part.split(": ", 1)[-1].strip()
                # Process complete entry
                sensor_name = current_desc + " " + current_index if "#" not in current_desc else current_desc
                
                # Filter humidity sensors only
                sensor_type = SENSOR_TYPE_NAMES.get(current_type, "unknown")
                if sensor_type in ["humidity", "humidityCombo"]:
                    # Guard for value conversion
                    if current_value.isdigit() or (current_value.startswith("-") and current_value[1:].isdigit()):
                        value = float(current_value) / 10.0
                        sensors[sensor_name] = {"value": value, "type": sensor_type}
        
        # Build discovery result
        items = []
        for item, sensor in sensors.items():
            items.append({
                "item": item,
                "params": {"levels": (15.0, 16.0), "levels_lower": (10.0, 9.0)},
                "metrics": ["humidity"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode - single item
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse sensors
    sensors = {}
    current_index = ""
    current_type = ""
    current_desc = ""
    current_value = ""
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        
        oid_part = parts[0]
        value_part = parts[1]
        
        suffix = oid_part.rsplit(".", 1)[-1]
        
        if oid_part.endswith(".1"):
            current_index = value_part.strip()
            current_desc = ""
            current_type = ""
            current_value = ""
        elif oid_part.endswith(".2"):
            current_type = value_part.split(": ", 1)[-1].strip()
        elif oid_part.endswith(".3"):
            current_desc = value_part.split(": ", 1)[-1].strip()
        elif oid_part.endswith(".4"):
            current_value = value_part.split(": ", 1)[-1].strip()
            sensor_name = current_desc + " " + current_index if "#" not in current_desc else current_desc
            sensor_type = SENSOR_TYPE_NAMES.get(current_type, "unknown")
            
            if sensor_type in ["humidity", "humidityCombo"]:
                # Guard for value conversion
                if current_value.isdigit() or (current_value.startswith("-") and current_value[1:].isdigit()):
                    value = float(current_value) / 10.0
                    sensors[sensor_name] = {"value": value, "type": sensor_type}
    
    # Check requested item
    if item not in sensors:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    humidity = sensors[item]["value"]
    
    # Get thresholds
    levels_upper = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])
    levels_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])
    
    warn_high, crit_high = levels_upper
    warn_low, crit_low = levels_lower
    
    # Determine state based on thresholds
    state = "OK"
    details = ""
    
    if humidity >= crit_high:
        state = "CRIT"
        details = "Critical: humidity %d%% >= %f%%" % (humidity, crit_high)
    elif humidity >= warn_high:
        state = "WARN"
        details = "Warning: humidity %d%% >= %f%%" % (humidity, warn_high)
    elif humidity <= crit_low:
        state = "CRIT"
        details = "Critical: humidity %d%% <= %f%%" % (humidity, crit_low)
    elif humidity <= warn_low:
        state = "WARN"
        details = "Warning: humidity %d%% <= %f%%" % (humidity, warn_low)
    
    # Format message
    msg = "Humidity: %d%%" % humidity
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": details
        }
    }
