def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.3699.1.1.9.1.4.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        SENSOR_TYPE_NAMES = {
            "0": "undefined", "1": "temperature", "2": "humidity", "3": "power",
            "4": "lowVoltage", "5": "current", "6": "aclmvVoltage", "7": "aclmpVoltage",
            "8": "aclmpPower", "9": "water", "10": "smoke", "11": "vibration",
            "12": "motion", "13": "glass", "14": "door", "15": "keypad",
            "16": "panicButton", "17": "keyStation", "18": "digInput", "22": "light",
            "24": "dewpoint", "26": "tacDio", "36": "acVoltage", "37": "acCurrent",
            "38": "dcVoltage", "39": "dcCurrent", "41": "rmsVoltage", "42": "rmsCurrent",
            "43": "activePower", "44": "reactivePower", "513": "tempHum",
            "32767": "custom", "32769": "temperatureCombo", "32770": "humidityCombo",
            "540": "tempHum",
        }
        
        # Parse SNMP output
        lines = res.stdout.splitlines()
        sensors = {}
        for line in lines:
            if "=" not in line:
                continue
            parts = line.split("=")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            if not value_part.startswith(":"):
                continue
            value = value_part[1:].strip()
            
            # Extract index from OID: base + ".<index>.<field>"
            base_oid = ".1.3.6.1.4.1.3699.1.1.9.1.4.1.1."
            if not oid_part.startswith(base_oid):
                continue
            suffix = oid_part[len(base_oid):]
            dots = suffix.split(".")
            if len(dots) < 2:
                continue
            idx_str = dots[0]
            field_str = dots[1]
            if not idx_str.isdigit() or not field_str.isdigit():
                continue
            idx = int(idx_str)
            field = int(field_str)
            
            if idx not in sensors:
                sensors[idx] = {}
            sensors[idx][field] = value
        
        # Build discovered items
        items = []
        for idx, fields in sensors.items():
            desc = fields.get(3, "")
            sensor_type = SENSOR_TYPE_NAMES.get(fields.get(2, ""), "unknown")
            # Only voltage sensors (type "power") for this check
            if sensor_type == "power":
                item_name = desc + " " + str(idx) if desc else str(idx)
                items.append({
                    "item": item_name,
                    "params": {"levels": (15.0, 16.0), "levels_lower": (10.0, 9.0)},
                    "metrics": ["voltage"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.3699.1.1.9.1.4.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    SENSOR_TYPE_NAMES = {
        "0": "undefined", "1": "temperature", "2": "humidity", "3": "power",
        "4": "lowVoltage", "5": "current", "6": "aclmvVoltage", "7": "aclmpVoltage",
        "8": "aclmpPower", "9": "water", "10": "smoke", "11": "vibration",
        "12": "motion", "13": "glass", "14": "door", "15": "keypad",
        "16": "panicButton", "17": "keyStation", "18": "digInput", "22": "light",
        "24": "dewpoint", "26": "tacDio", "36": "acVoltage", "37": "acCurrent",
        "38": "dcVoltage", "39": "dcCurrent", "41": "rmsVoltage", "42": "rmsCurrent",
        "43": "activePower", "44": "reactivePower", "513": "tempHum",
        "32767": "custom", "32769": "temperatureCombo", "32770": "humidityCombo",
        "540": "tempHum",
    }
    
    lines = res.stdout.splitlines()
    sensors = {}
    for line in lines:
        if "=" not in line:
            continue
        parts = line.split("=")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if not value_part.startswith(":"):
            continue
        value = value_part[1:].strip()
        
        base_oid = ".1.3.6.1.4.1.3699.1.1.9.1.4.1.1."
        if not oid_part.startswith(base_oid):
            continue
        suffix = oid_part[len(base_oid):]
        dots = suffix.split(".")
        if len(dots) < 2:
            continue
        idx_str = dots[0]
        field_str = dots[1]
        if not idx_str.isdigit() or not field_str.isdigit():
            continue
        idx = int(idx_str)
        field = int(field_str)
        
        if idx not in sensors:
            sensors[idx] = {}
        sensors[idx][field] = value
    
    # Find matching sensor
    sensor_value = None
    for idx, fields in sensors.items():
        desc = fields.get(3, "")
        item_name = desc + " " + str(idx) if desc else str(idx)
        if item_name == item:
            sensor_type = SENSOR_TYPE_NAMES.get(fields.get(2, ""), "unknown")
            if sensor_type != "power":
                return {
                    "changed": False,
                    "msg": "item is not a voltage sensor",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            val_str = fields.get(6, "")
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                sensor_value = float(val_str) / 10.0
            else:
                return {
                    "changed": False,
                    "msg": "sensor value not parseable",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            break
    
    if sensor_value == None:
        return {
            "changed": False,
            "msg": "no such sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Thresholds
    levels = params.get("levels", (15.0, 16.0))
    levels_lower = params.get("levels_lower", (10.0, 9.0))
    upper_warn, upper_crit = levels
    lower_warn, lower_crit = levels_lower
    
    # Determine state
    state = "OK"
    if sensor_value >= upper_crit:
        state = "CRIT"
    elif sensor_value >= upper_warn:
        state = "WARN"
    elif sensor_value <= lower_crit:
        state = "CRIT"
    elif sensor_value <= lower_warn:
        state = "WARN"
    
    msg = "Input Voltage is %f V" % sensor_value
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"voltage": sensor_value},
            "details": ""
        }
    }
