# Sensor type names mapping
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

# Default check parameters for voltage sensors
ENVIROMUX_CHECK_DEFAULT_PARAMETERS = {
    "levels": [15.0, 16.0],
    "levels_lower": [10.0, 9.0],
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Determine SNMP base OID based on detection
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), 
                      "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], 
                      mutates=False)
        sys_oid = ""
        for line in res.stdout.splitlines():
            if "=" in line:
                parts = line.split("=", 1)
                if len(parts) == 2:
                    val = parts[1].strip()
                    if val.startswith("OID:"):
                        val = val[4:].strip()
                    sys_oid = val
                    break
        
        # Use enviromux5 base OID for detection
        base_oid = ".1.3.6.1.4.1.3699.1.1.10.1.4.1.1" if (sys_oid != "" and ".1.3.6.1.4.1.3699.1.1.10" in sys_oid) else ".1.3.6.1.4.1.3699.1.1.11.1.4.1.1"
        
        # Walk all fields we need
        sensor_data = {}
        for field_idx in [1, 2, 3, 6, 10, 11]:
            oid = base_oid + "." + str(field_idx)
            res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"), oid], mutates=False)
            
            for line in res.stdout.splitlines():
                if "=" not in line:
                    continue
                parts = line.split("=", 1)
                if len(parts) != 2:
                    continue
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                
                # Extract index from OID
                oid_parts = oid_part.split(".")
                if len(oid_parts) < 14:
                    continue
                index = int(oid_parts[-1]) if oid_parts[-1].isdigit() else 0
                if index == 0 and not oid_parts[-1].isdigit():
                    continue
                
                value_str = value_part
                if ":" in value_str:
                    value_str = value_str.split(":", 1)[1].strip()
                
                if index not in sensor_data:
                    sensor_data[index] = {}
                sensor_data[index][field_idx] = value_str
        
        # Process sensors - discover only voltage sensors
        discovered = []
        for idx, data in sensor_data.items():
            sensor_type = data.get(2, "0")
            type_name = SENSOR_TYPE_NAMES.get(sensor_type, "unknown")
            if type_name == "power":
                desc = data.get(3, "")
                if desc.startswith('"') and desc.endswith('"'):
                    desc = desc[1:-1]
                item = "%s %s" % (desc, idx) if desc else "%s" % idx
                discovered.append({
                    "item": item,
                    "params": ENVIROMUX_CHECK_DEFAULT_PARAMETERS,
                    "metrics": ["voltage"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Determine base OID
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"], 
                  mutates=False)
    sys_oid = ""
    for line in res.stdout.splitlines():
        if "=" in line:
            parts = line.split("=", 1)
            if len(parts) == 2:
                val = parts[1].strip()
                if val.startswith("OID:"):
                    val = val[4:].strip()
                sys_oid = val
                break
    
    base_oid = ".1.3.6.1.4.1.3699.1.1.10.1.4.1.1" if (sys_oid != "" and ".1.3.6.1.4.1.3699.1.1.10" in sys_oid) else ".1.3.6.1.4.1.3699.1.1.11.1.4.1.1"
    
    # Get sensor data
    sensor_data = {}
    for field_idx in [1, 2, 3, 6, 10, 11]:
        oid = base_oid + "." + str(field_idx)
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        for line in res.stdout.splitlines():
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            oid_parts = oid_part.split(".")
            if len(oid_parts) < 14:
                continue
            index = int(oid_parts[-1]) if oid_parts[-1].isdigit() else 0
            if index == 0 and not oid_parts[-1].isdigit():
                continue
            value_str = value_part
            if ":" in value_str:
                value_str = value_str.split(":", 1)[1].strip()
            if index not in sensor_data:
                sensor_data[index] = {}
            sensor_data[index][field_idx] = value_str
    
    # Find matching sensor by item name
    sensor = None
    for idx, data in sensor_data.items():
        desc = data.get(3, "")
        if desc.startswith('"') and desc.endswith('"'):
            desc = desc[1:-1]
        sensor_name = "%s %s" % (desc, idx) if desc else "%s" % idx
        if sensor_name == item:
            sensor = data
            break
    
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get voltage value (field 6)
    value_str = sensor.get(6, "")
    if not value_str:
        return {
            "changed": False,
            "msg": "no value for sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse value
    if ":" in value_str:
        value_str = value_str.split(":", 1)[1].strip()
    
    # Convert to float using string.isdigit() guard
    value = float(value_str) if value_str.replace(".", "").replace("-", "").isdigit() else 0.0
    
    # Apply scaling: voltage values are in 1/10 units
    value = value / 10.0
    
    # Get thresholds (field 10 and 11)
    min_str = sensor.get(10, "")
    max_str = sensor.get(11, "")
    
    # Parse thresholds
    min_val = None
    max_val = None
    if min_str:
        if ":" in min_str:
            min_str = min_str.split(":", 1)[1].strip()
        if min_str.replace(".", "").replace("-", "").isdigit():
            min_val = float(min_str) / 10.0
    
    if max_str:
        if ":" in max_str:
            max_str = max_str.split(":", 1)[1].strip()
        if max_str.replace(".", "").replace("-", "").isdigit():
            max_val = float(max_str) / 10.0
    
    # Get parameters
    levels = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS.get("levels", [15.0, 16.0]))
    levels_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS.get("levels_lower", [10.0, 9.0]))
    
    # Determine state based on thresholds
    state = "OK"
    summary = "voltage %f V" % value
    if max_val != None and value >= max_val:
        state = "CRIT"
        summary = "voltage %f V exceeds maximum threshold %f V" % (value, max_val)
    elif value >= levels[0]:
        state = "WARN"
        summary = "voltage %f V exceeds warning threshold %f V" % (value, levels[0])
    elif min_val != None and value <= min_val:
        state = "CRIT"
        summary = "voltage %f V is below minimum threshold %f V" % (value, min_val)
    elif value <= levels_lower[0]:
        state = "WARN"
        summary = "voltage %f V is below warning threshold %f V" % (value, levels_lower[0])
    
    # Add thresholds to details
    details = ""
    if max_val != None:
        details = "max threshold: %f V" % max_val
    if min_val != None:
        details = details + ", min threshold: %f V" % min_val if details else "min threshold: %f V" % min_val
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"voltage": value},
            "details": details
        }
    }