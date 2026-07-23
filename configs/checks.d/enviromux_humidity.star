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

DEFAULT_WARN = 15.0
DEFAULT_CRIT = 16.0
DEFAULT_WARN_LOWER = 10.0
DEFAULT_CRIT_LOWER = 9.0


def _is_numeric(s):
    if s == "":
        return False
    for c in s:
        if c < "0" or c > "9":
            return False
    return True


def _parse_snmp_table(res):
    lines = res.stdout.splitlines()
    sensors = []
    current_sensor = {}
    
    for line in lines:
        line = line.strip()
        if line == "":
            continue
        idx = line.find("=")
        if idx == -1:
            continue
        oid_part = line[:idx].strip()
        value_part = line[idx + 1:].strip()
        
        parts = oid_part.rsplit(".", 1)
        if len(parts) != 2:
            continue
        suffix = parts[1]
        
        val_str = ""
        colon_idx = value_part.find(": ")
        if colon_idx != -1:
            val_str = value_part[colon_idx + 2:]
        else:
            val_str = value_part
        
        val_str = val_str.strip()
        val = 0.0
        if _is_numeric(val_str) or (val_str.find(".") != -1 and _is_numeric(val_str.replace(".", ""))):
            val = float(val_str)
        else:
            continue
        
        if suffix == "1":
            current_sensor["index"] = val
        elif suffix == "2":
            current_sensor["type"] = val
        elif suffix == "3":
            current_sensor["description"] = val_str
        elif suffix == "6":
            current_sensor["value"] = val
        elif suffix == "10":
            current_sensor["min_threshold"] = val
        elif suffix == "11":
            current_sensor["max_threshold"] = val
        
        if "index" in current_sensor and "value" in current_sensor and "description" in current_sensor:
            sensors.append(current_sensor)
            current_sensor = {}
    
    return sensors


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.3699.1.1.11.1.3.1.1"
    
    if params.get("_discover") == True:
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1", base_oid + ".2", base_oid + ".3",
            base_oid + ".6", base_oid + ".10", base_oid + ".11"
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }
        
        sensors = _parse_snmp_table(res)
        items = []
        
        for sensor in sensors:
            type_val = sensor.get("type", 0)
            sensor_type = SENSOR_TYPE_NAMES.get(str(int(type_val)), "unknown")
            if sensor_type == "humidity" or sensor_type == "humidityCombo":
                item_name = sensor.get("description", "") + " " + str(int(sensor.get("index", 0)))
                items.append({
                    "item": item_name,
                    "params": {
                        "levels": [DEFAULT_WARN, DEFAULT_CRIT],
                        "levels_lower": [DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER]
                    },
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items}
        }
    
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1", base_oid + ".2", base_oid + ".3",
        base_oid + ".6", base_oid + ".10", base_oid + ".11"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    sensors = _parse_snmp_table(res)
    
    sensor = None
    for s in sensors:
        sensor_name = s.get("description", "") + " " + str(int(s.get("index", 0)))
        if sensor_name == item:
            sensor = s
            break
    
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    type_val = sensor.get("type", 0)
    sensor_type = SENSOR_TYPE_NAMES.get(str(int(type_val)), "unknown")
    if sensor_type != "humidity" and sensor_type != "humidityCombo":
        return {
            "changed": False,
            "msg": "sensor is not humidity: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    humidity_val = sensor.get("value", None)
    if humidity_val == None:
        return {
            "changed": False,
            "msg": "humidity value not available for sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    warn = params.get("levels", [DEFAULT_WARN, DEFAULT_CRIT])[0]
    crit = params.get("levels", [DEFAULT_WARN, DEFAULT_CRIT])[1]
    warn_lower = params.get("levels_lower", [DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER])[0]
    crit_lower = params.get("levels_lower", [DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER])[1]
    
    state = "OK"
    if humidity_val >= crit:
        state = "CRIT"
    elif humidity_val >= warn:
        state = "WARN"
    elif humidity_val <= crit_lower:
        state = "CRIT"
    elif humidity_val <= warn_lower:
        state = "WARN"
    
    msg = item + " humidity: %f%%" % humidity_val
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity_val},
            "details": ""
        }
    }