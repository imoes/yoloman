# Module-level constants (required maps)
SENSOR_TYPE_TEMP = "1"
SENSOR_TYPE_TEMP_HUM = "2"

# Helper: convert sensor_id to description (same as Checkmk)
def _sensor_descr(sensor_id):
    if sensor_id == "0":
        return "internal"
    return "external " + sensor_id

# Helper: parse a single sensor line and extract (sensor_id, sensor_type, temp, hum)
def _parse_line(line):
    parts = line.strip().split("|")
    if len(parts) < 4:
        return None
    # Convert empty strings to "0" for missing fields
    sensor_id = parts[0].strip()
    sensor_type = parts[1].strip()
    temp = parts[2].strip() if parts[2].strip() != "" else "0"
    hum = parts[3].strip() if parts[3].strip() != "" else "0"
    return (sensor_id, sensor_type, temp, hum)

# Helper: compute state from temperature value and params
def _check_temperature(temperature, params):
    levels = params.get("levels", (28.0, 35.0))
    levels_lower = params.get("levels_lower", (13.0, 17.0))
    
    # Upper levels
    warn_upper = levels[0] if len(levels) >= 1 else None
    crit_upper = levels[1] if len(levels) >= 2 else None
    
    # Lower levels
    warn_lower = levels_lower[0] if len(levels_lower) >= 1 else None
    crit_lower = levels_lower[1] if len(levels_lower) >= 2 else None
    
    # Determine state
    if crit_upper != None and temperature >= crit_upper:
        return "CRIT"
    if warn_upper != None and temperature >= warn_upper:
        return "WARN"
    if crit_lower != None and temperature <= crit_lower:
        return "CRIT"
    if warn_lower != None and temperature <= warn_lower:
        return "WARN"
    return "OK"

# Helper: compute state from humidity value and params (Checkmk-style levels)
def _check_humidity(humidity, params):
    levels = params.get("levels", (60, 65))
    
    warn_upper = levels[0] if len(levels) >= 1 else None
    crit_upper = levels[1] if len(levels) >= 2 else None
    
    # Lower levels default for humidity: always use lower bound
    # The Checkmk default for humidity has no lower levels defined, but we follow the source
    levels_lower = params.get("levels_lower", (40, 35))
    warn_lower = levels_lower[0] if len(levels_lower) >= 1 else None
    crit_lower = levels_lower[1] if len(levels_lower) >= 2 else None
    
    # Determine state
    if crit_upper != None and humidity >= crit_upper:
        return "CRIT"
    if warn_upper != None and humidity >= warn_upper:
        return "WARN"
    if crit_lower != None and humidity <= crit_lower:
        return "CRIT"
    if warn_lower != None and humidity <= warn_lower:
        return "WARN"
    return "OK"

# Helper: extract value from snmpwalk output line
def _extract_snmp_value(line):
    parts = line.strip().split(" = ")
    if len(parts) < 2:
        return None, None
    oid = parts[0].strip()
    value_part = parts[1].strip()
    type_value = value_part.split(": ", 1)
    if len(type_value) < 2:
        return None, None
    return oid, type_value[1].strip()

# Helper: parse sensor data from snmpwalk output
def _parse_sensor_data(output):
    sensor_data = {}
    current_id = ""
    for line in output.splitlines():
        oid, value = _extract_snmp_value(line)
        if oid == None:
            continue
        
        # Get suffix from OID: base is .1.3.6.1.4.1.21695.1.10.7.3.1
        # OID suffixes: .1 -> sensor_id, .2 -> sensor_type, .4 -> temp, .5 -> hum
        suffix_parts = oid.split(".")
        if len(suffix_parts) < 10:
            continue
        suffix = suffix_parts[-1]
        
        if suffix == "1":
            current_id = value
            sensor_data[current_id] = {"id": current_id, "type": None, "temp": None, "hum": None}
        elif suffix == "2":
            sensor_data[current_id]["type"] = value
        elif suffix == "4":
            sensor_data[current_id]["temp"] = value
        elif suffix == "5":
            sensor_data[current_id]["hum"] = value
    
    return sensor_data

# Main entry point
def main(ctx, params):
    # Detect mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.21695.1.10.7.3.1"
        ], mutates=False)
        
        sensor_data = _parse_sensor_data(res.stdout)
        
        # Build discovery list
        out = []
        for sid, data in sensor_data.items():
            sensor_id = data["id"]
            sensor_type = data.get("type")
            # Temperature service for sensor_type "1" (temp) or "2" (temp+hum)
            if sensor_type == SENSOR_TYPE_TEMP or sensor_type == SENSOR_TYPE_TEMP_HUM:
                out.append({
                    "item": _sensor_descr(sensor_id),
                    "params": {"levels": (28.0, 35.0), "levels_lower": (13.0, 17.0)},
                    "metrics": ["temperature"]
                })
            # Humidity service only for sensor_type "2" (temp+hum)
            if sensor_type == SENSOR_TYPE_TEMP_HUM:
                out.append({
                    "item": _sensor_descr(sensor_id),
                    "params": {"levels": (60, 65), "levels_lower": (40, 35)},
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d services" % len(out),
            "data": {"discovery": out}
        }
    
    # CHECK mode
    item = params.get("item", "")
    
    # Determine if this is humidity check by checking item description
    is_humidity = False
    if item.find("Humidity") != -1:
        is_humidity = True
    
    # Re-fetch the same data as discovery
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.21695.1.10.7.3.1"
    ], mutates=False)
    
    # Rebuild sensor_data dict as in discovery
    sensor_data = _parse_sensor_data(res.stdout)
    
    # Find matching sensor
    found = False
    for sid, data in sensor_data.items():
        if _sensor_descr(data["id"]) == item:
            found = True
            sensor_type = data.get("type")
            
            if not is_humidity and (sensor_type == SENSOR_TYPE_TEMP or sensor_type == SENSOR_TYPE_TEMP_HUM):
                temp_str = data.get("temp", "0")
                if temp_str.isdigit() or (temp_str.find(".") != -1 and temp_str.replace(".", "").replace("-", "").isdigit()):
                    temperature = float(temp_str) / 10.0
                else:
                    return {
                        "changed": False,
                        "msg": "invalid temperature data: " + temp_str,
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                    }
                state = _check_temperature(temperature, params)
                msg = "Temperature: %f C" % temperature
                return {
                    "changed": False,
                    "msg": msg,
                    "data": {"state": state, "metrics": {"temperature": temperature}, "details": ""}
                }
            elif is_humidity and sensor_type == SENSOR_TYPE_TEMP_HUM:
                hum_str = data.get("hum", "0")
                if hum_str.isdigit() or (hum_str.find(".") != -1 and hum_str.replace(".", "").replace("-", "").isdigit()):
                    humidity = float(hum_str) / 10.0
                else:
                    return {
                        "changed": False,
                        "msg": "invalid humidity data: " + hum_str,
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                    }
                state = _check_humidity(humidity, params)
                msg = "Humidity: %f %%rH" % humidity
                return {
                    "changed": False,
                    "msg": msg,
                    "data": {"state": state, "metrics": {"humidity": humidity}, "details": ""}
                }
    
    # Item not found
    if not found:
        return {
            "changed": False,
            "msg": "sensor item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
