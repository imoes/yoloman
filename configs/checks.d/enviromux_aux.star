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

def _walk_snmp(ctx, base_oid, community, host):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid
    ], mutates=False)
    return res.stdout

def _parse_snmp_output(stdout):
    sensors = {}
    for line in stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()
        if ":" in value:
            value = value.split(":", 1)[1].strip()
        oid_parts = oid_full.split(".")
        row_index = oid_parts[-2]
        col_index = int(oid_parts[-1])
        if row_index not in sensors:
            sensors[row_index] = {}
        field_map = {
            1: "index",
            2: "type",
            3: "description",
            6: "value",
            10: "min_threshold",
            11: "max_threshold"
        }
        field = field_map.get(col_index)
        if field:
            sensors[row_index][field] = value
    return sensors

def _check_temperature(reading, params):
    warn_upper = params.get("levels", (15.0, 16.0))[1]
    crit_upper = params.get("levels", (15.0, 16.0))[0]
    warn_lower = params.get("levels_lower", (10.0, 9.0))[1]
    crit_lower = params.get("levels_lower", (10.0, 9.0))[0]
    
    if reading >= crit_upper or reading <= crit_lower:
        state = "CRIT"
    elif reading >= warn_upper or reading <= warn_lower:
        state = "WARN"
    else:
        state = "OK"
    
    return state

def _check_humidity(humidity, params):
    warn_upper = params.get("levels", (60.0, 80.0))[1]
    crit_upper = params.get("levels", (60.0, 80.0))[0]
    warn_lower = params.get("levels_lower", (20.0, 15.0))[1]
    crit_lower = params.get("levels_lower", (20.0, 15.0))[0]
    
    if humidity >= crit_upper or humidity <= crit_lower:
        state = "CRIT"
    elif humidity >= warn_upper or humidity <= warn_lower:
        state = "WARN"
    else:
        state = "OK"
    
    return state

def _check_voltage(value, params):
    levels = params.get("levels", (15.0, 16.0))
    levels_lower = params.get("levels_lower", (10.0, 9.0))
    
    upper_warn = levels[1]
    upper_crit = levels[0]
    lower_warn = levels_lower[1]
    lower_crit = levels_lower[0]
    
    if value >= upper_crit or value <= lower_crit:
        state = "CRIT"
    elif value >= upper_warn or value <= lower_warn:
        state = "WARN"
    else:
        state = "OK"
    
    return state

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    if params.get("_discover"):
        base_oid1 = ".1.3.6.1.4.1.3699.1.1.11.1.4.1.1"
        base_oid2 = ".1.3.6.1.4.1.3699.1.1.10.1.4.1.1"
        
        output1 = _walk_snmp(ctx, base_oid1, community, host)
        output2 = _walk_snmp(ctx, base_oid2, community, host)
        
        raw_sensors = {}
        if output1.strip():
            raw_sensors = _parse_snmp_output(output1)
        elif output2.strip():
            raw_sensors = _parse_snmp_output(output2)
        else:
            return {"changed": False, "msg": "discovered 0 sensors", "data": {"discovery": []}}
        
        discovery = []
        for row_idx, sensor_data in raw_sensors.items():
            if "description" not in sensor_data or "type" not in sensor_data:
                continue
            
            sensor_type = sensor_data.get("type", "")
            sensor_type_name = SENSOR_TYPE_NAMES.get(sensor_type, "unknown")
            
            if sensor_type_name not in ["temperature", "temperatureCombo", "power", "humidity", "humidityCombo"]:
                continue
            
            item_name = sensor_data.get("description", "").strip()
            index = sensor_data.get("index", row_idx)
            if item_name == "":
                item_name = "%s %s" % (sensor_type_name, index)
            else:
                item_name = item_name + " " + index
            
            suggested_params = {}
            if sensor_type_name in ["humidity", "humidityCombo"]:
                suggested_params = {"levels": (60.0, 80.0), "levels_lower": (20.0, 15.0)}
            elif sensor_type_name == "power":
                suggested_params = {"levels": (15.0, 16.0), "levels_lower": (10.0, 9.0)}
            else:
                suggested_params = {"levels": (15.0, 16.0), "levels_lower": (10.0, 9.0)}
            
            metrics = []
            if sensor_type_name in ["temperature", "temperatureCombo"]:
                metrics = ["temperature"]
            elif sensor_type_name == "power":
                metrics = ["voltage"]
            elif sensor_type_name in ["humidity", "humidityCombo"]:
                metrics = ["humidity"]
            
            if metrics:
                discovery.append({
                    "item": item_name,
                    "params": suggested_params,
                    "metrics": metrics
                })
        
        return {"changed": False, "msg": "discovered %d sensors" % len(discovery),
                "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    base_oid1 = ".1.3.6.1.4.1.3699.1.1.11.1.4.1.1"
    base_oid2 = ".1.3.6.1.4.1.3699.1.1.10.1.4.1.1"
    
    output1 = _walk_snmp(ctx, base_oid1, community, host)
    output2 = _walk_snmp(ctx, base_oid2, community, host)
    
    raw_sensors = {}
    if output1.strip():
        raw_sensors = _parse_snmp_output(output1)
    elif output2.strip():
        raw_sensors = _parse_snmp_output(output2)
    else:
        return {"changed": False, "msg": "no sensor data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    sensor = None
    sensor_type_name = None
    for row_idx, sensor_data in raw_sensors.items():
        if "description" not in sensor_data or "type" not in sensor_data:
            continue
        
        desc = sensor_data.get("description", "").strip()
        index = sensor_data.get("index", row_idx)
        if desc == "":
            sensor_item = "%s %s" % (SENSOR_TYPE_NAMES.get(sensor_data.get("type", ""), "unknown"), index)
        else:
            sensor_item = desc + " " + index
        
        if sensor_item == item:
            sensor_type_name = SENSOR_TYPE_NAMES.get(sensor_data.get("type", ""), "unknown")
            value_str = sensor_data.get("value", "0")
            value = float(value_str) if value_str.isdigit() or value_str.replace('.', '').replace('-', '').isdigit() else 0.0
            
            if sensor_type_name in ["temperature", "power", "current", "temperatureCombo"]:
                value /= 10.0
            
            min_threshold_str = sensor_data.get("min_threshold", "0")
            max_threshold_str = sensor_data.get("max_threshold", "0")
            min_threshold = float(min_threshold_str) / 10.0 if min_threshold_str.isdigit() or min_threshold_str.replace('.', '').replace('-', '').isdigit() else None
            max_threshold = float(max_threshold_str) / 10.0 if max_threshold_str.isdigit() or max_threshold_str.replace('.', '').replace('-', '').isdigit() else None
            if sensor_type_name not in ["temperature", "power", "current", "temperatureCombo"]:
                min_threshold = float(min_threshold_str) if min_threshold_str.isdigit() or min_threshold_str.replace('.', '').replace('-', '').isdigit() else None
                max_threshold = float(max_threshold_str) if max_threshold_str.isdigit() or max_threshold_str.replace('.', '').replace('-', '').isdigit() else None
            
            sensor = {
                "value": value,
                "min_threshold": min_threshold,
                "max_threshold": max_threshold
            }
            break
    
    if sensor == None:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state = "UNKNOWN"
    metrics = {}
    msg = ""
    
    if sensor_type_name in ["temperature", "temperatureCombo"]:
        state = _check_temperature(sensor["value"], params)
        metrics = {"temperature": sensor["value"]}
        msg = "Temperature: %f C" % sensor["value"]
        if sensor["max_threshold"] != None:
            msg += ", Max: %f C" % sensor["max_threshold"]
        if sensor["min_threshold"] != None:
            msg += ", Min: %f C" % sensor["min_threshold"]
    elif sensor_type_name == "humidity" or sensor_type_name == "humidityCombo":
        state = _check_humidity(sensor["value"], params)
        metrics = {"humidity": sensor["value"]}
        msg = "Humidity: %f %%" % sensor["value"]
        if sensor["max_threshold"] != None:
            msg += ", Max: %f %%" % sensor["max_threshold"]
        if sensor["min_threshold"] != None:
            msg += ", Min: %f %%" % sensor["min_threshold"]
    elif sensor_type_name == "power":
        state = _check_voltage(sensor["value"], params)
        metrics = {"voltage": sensor["value"]}
        msg = "Voltage: %f V" % sensor["value"]
        if sensor["max_threshold"] != None:
            msg += ", Max: %f V" % sensor["max_threshold"]
        if sensor["min_threshold"] != None:
            msg += ", Min: %f V" % sensor["min_threshold"]
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
