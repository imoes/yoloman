def main(ctx, params):
    # Module constants (maps from Checkmk source)
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

    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            ".1.3.6.1.4.1.3699.1.1.2.1.4.1.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed: " + res.stderr,
                "data": {"discovery": []}
            }
        
        lines = res.stdout.splitlines()
        sensors = {}
        
        for line in lines:
            if not line.strip():
                continue
            
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            suffix = oid_part.rsplit(".", 1)[-1]
            
            if value_part.startswith("STRING: "):
                value = value_part[8:].strip('"')
            elif value_part.startswith("INTEGER: "):
                value = value_part[9:]
            elif value_part.startswith("Gauge32: "):
                value = value_part[9:]
            else:
                value = value_part
            
            sensors.setdefault(suffix, []).append(value)
        
        discovery_items = []
        
        for idx in sorted(sensors.keys()):
            values = sensors[idx]
            if len(values) < 6:
                continue
            
            sensor_type = values[1]
            desc = values[2]
            sensor_name = desc + " " + idx
            
            type_name = SENSOR_TYPE_NAMES.get(sensor_type, "unknown")
            
            if type_name in ["temperature", "temperatureCombo"]:
                discovery_items.append({
                    "item": sensor_name,
                    "params": {},
                    "metrics": ["temperature"]
                })
            elif type_name == "power":
                discovery_items.append({
                    "item": sensor_name,
                    "params": ENVIROMUX_CHECK_DEFAULT_PARAMETERS,
                    "metrics": ["voltage"]
                })
            elif type_name in ["humidity", "humidityCombo"]:
                discovery_items.append({
                    "item": sensor_name,
                    "params": {},
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    parts = item.rsplit(" ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    index = parts[1]
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host,
        ".1.3.6.1.4.1.3699.1.1.2.1.4.1.1.2." + index,
        ".1.3.6.1.4.1.3699.1.1.2.1.4.1.1.3." + index,
        ".1.3.6.1.4.1.3699.1.1.2.1.4.1.1.6." + index,
        ".1.3.6.1.4.1.3699.1.1.2.1.4.1.1.10." + index,
        ".1.3.6.1.4.1.3699.1.1.2.1.4.1.1.11." + index
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for item " + item + ": " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    values = {}
    
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        
        oid = parts[0].strip()
        val = parts[1].strip()
        
        suffix = oid.rsplit(".", 1)[-1]
        if suffix == "2":
            if val.startswith("STRING: "):
                values["type"] = val[8:]
            else:
                values["type"] = val
        elif suffix == "3":
            if val.startswith("STRING: "):
                values["desc"] = val[8:]
            else:
                values["desc"] = val
        elif suffix == "6":
            if val.startswith("INTEGER: "):
                v = val[9:]
                values["value"] = float(v) if v.replace(".", "").replace("-", "").isdigit() else 0.0
            else:
                v = val
                values["value"] = float(v) if v.replace(".", "").replace("-", "").isdigit() else 0.0
        elif suffix == "10":
            if val.startswith("INTEGER: "):
                v = val[9:]
                values["min"] = float(v) if v.replace(".", "").replace("-", "").isdigit() else None
            else:
                v = val
                values["min"] = float(v) if v.replace(".", "").replace("-", "").isdigit() else None
        elif suffix == "11":
            if val.startswith("INTEGER: "):
                v = val[9:]
                values["max"] = float(v) if v.replace(".", "").replace("-", "").isdigit() else None
            else:
                v = val
                values["max"] = float(v) if v.replace(".", "").replace("-", "").isdigit() else None
    
    if "type" not in values or "value" not in values:
        return {
            "changed": False,
            "msg": "sensor data incomplete",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    sensor_type = values["type"]
    value = values["value"]
    min_threshold = values.get("min")
    max_threshold = values.get("max")
    
    type_name = SENSOR_TYPE_NAMES.get(sensor_type, "unknown")
    
    if type_name in ["temperature", "power", "current", "temperatureCombo"]:
        value = value / 10.0
        if min_threshold != None:
            min_threshold = min_threshold / 10.0
        if max_threshold != None:
            max_threshold = max_threshold / 10.0
    
    if type_name in ["temperature", "temperatureCombo"]:
        warn = params.get("warn", None)
        crit = params.get("crit", None)
        warn_lower = params.get("warn_lower", None)
        crit_lower = params.get("crit_lower", None)
        
        dev_levels_upper = None
        dev_levels_lower = None
        if max_threshold != None:
            dev_levels_upper = (max_threshold, max_threshold)
        if min_threshold != None:
            dev_levels_lower = (min_threshold, min_threshold)
        
        state = "OK"
        details = ""
        
        if crit != None and value >= crit:
            state = "CRIT"
            details = "Crit: %s" % str(crit)
        elif warn != None and value >= warn:
            state = "WARN"
            details = "Warn: %s" % str(warn)
        
        if crit_lower != None and value <= crit_lower:
            state = "CRIT"
            details = details + ", CritLower: %s" % str(crit_lower)
        elif warn_lower != None and value <= warn_lower:
            state = "WARN"
            details = details + ", WarnLower: %s" % str(warn_lower)
        
        if state == "OK" and dev_levels_upper != None and value >= dev_levels_upper[0]:
            state = "WARN"
            details = "Device max: %s" % str(dev_levels_upper[0])
        if state == "OK" and dev_levels_lower != None and value <= dev_levels_lower[0]:
            state = "WARN"
            details = details + ", Device min: %s" % str(dev_levels_lower[0])
        
        return {
            "changed": False,
            "msg": "Temperature: %f C" % value + (", " + details if details else ""),
            "data": {
                "state": state,
                "metrics": {"temperature": value},
                "details": details
            }
        }
    
    elif type_name == "power":
        levels = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS.get("levels", (15.0, 16.0)))
        levels_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS.get("levels_lower", (10.0, 9.0)))
        
        warn_upper = levels[0]
        crit_upper = levels[1]
        warn_lower = levels_lower[0]
        crit_lower = levels_lower[1]
        
        state = "OK"
        details = ""
        
        if crit_upper != None and value >= crit_upper:
            state = "CRIT"
            details = "Crit: %s" % str(crit_upper)
        elif warn_upper != None and value >= warn_upper:
            state = "WARN"
            details = "Warn: %s" % str(warn_upper)
        
        if crit_lower != None and value <= crit_lower:
            state = "CRIT"
            details = details + ", CritLower: %s" % str(crit_lower)
        elif warn_lower != None and value <= warn_lower:
            state = "WARN"
            details = details + ", WarnLower: %s" % str(warn_lower)
        
        return {
            "changed": False,
            "msg": "Voltage: %f V" % value + (", " + details if details else ""),
            "data": {
                "state": state,
                "metrics": {"voltage": value},
                "details": details
            }
        }
    
    elif type_name in ["humidity", "humidityCombo"]:
        levels_upper = params.get("levels", None)
        levels_lower = params.get("levels_lower", None)
        
        warn_upper = 60.0
        crit_upper = 70.0
        warn_lower = 20.0
        crit_lower = 10.0
        
        if levels_upper != None:
            warn_upper = levels_upper[0]
            crit_upper = levels_upper[1]
        if levels_lower != None:
            warn_lower = levels_lower[0]
            crit_lower = levels_lower[1]
        
        state = "OK"
        details = ""
        
        if crit_upper != None and value >= crit_upper:
            state = "CRIT"
            details = "Crit: %s" % str(crit_upper)
        elif warn_upper != None and value >= warn_upper:
            state = "WARN"
            details = "Warn: %s" % str(warn_upper)
        
        if crit_lower != None and value <= crit_lower:
            state = "CRIT"
            details = details + ", CritLower: %s" % str(crit_lower)
        elif warn_lower != None and value <= warn_lower:
            state = "WARN"
            details = details + ", WarnLower: %s" % str(warn_lower)
        
        return {
            "changed": False,
            "msg": "Humidity: %f %%rH" % value + (", " + details if details else ""),
            "data": {
                "state": state,
                "metrics": {"humidity": value},
                "details": details
            }
        }
    
    else:
        return {
            "changed": False,
            "msg": "unknown sensor type: " + type_name,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }