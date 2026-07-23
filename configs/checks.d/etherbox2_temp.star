def main(ctx, params):
    # SNMP base OIDs from the Checkmk plugin
    base_indicator = ".1.3.6.1.4.1.14848.2.1.7.1"
    base_sensor = ".1.3.6.1.4.1.14848.2.1.9.1"
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discovery mode: enumerate all temperature sensors
    if params.get("_discover"):
        # Fetch all sensor indicators (base + 2) and sensor values
        indicator_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_indicator + ".2"
        ], mutates=False)
        
        sensor_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_sensor
        ], mutates=False)
        
        if indicator_res.rc != 0 or sensor_res.rc != 0:
            return {"changed": False, "msg": "SNMP query failed", "data": {"discovery": []}}
        
        indicator_lines = indicator_res.stdout.strip().splitlines() if indicator_res.stdout.strip() else []
        sensor_lines = sensor_res.stdout.strip().splitlines() if sensor_res.stdout.strip() else []
        
        # Build sensor values map: index -> list of values
        sensor_values = {}
        for line in sensor_lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract numeric part from OID end
            numeric = ""
            for ch in oid_part[::-1]:
                if ch.isdigit():
                    numeric = ch + numeric
                elif ch == '.':
                    break
            idx = int(numeric) if numeric else 0
            
            # Value parsing
            if value_part.startswith("STRING: "):
                value_str = value_part[8:].strip()
            elif value_part.startswith("INTEGER: "):
                value_str = value_part[9:].strip()
            else:
                value_str = value_part
            
            if idx not in sensor_values:
                sensor_values[idx] = []
            sensor_values[idx].append(value_str)
        
        # Build discovered items
        discovered = []
        num_sensors = len(indicator_lines) // 2
        
        for sensor_idx in range(num_sensors):
            indicator1 = sensor_values.get(2 * sensor_idx + 1, [""])[0] if (2 * sensor_idx + 1) in sensor_values else ""
            indicator2 = sensor_values.get(2 * sensor_idx + 2, [""])[0] if (2 * sensor_idx + 2) in sensor_values else ""
            
            # Extract voltage values safely
            v1 = 0.0
            v2 = 0.0
            if "Volt" in indicator1:
                parts1 = indicator1.split("Volt")[0].strip()
                if parts1:
                    v1 = float(parts1) if parts1.replace(".", "", 1).replace("-", "", 1).isdigit() else 0.0
            
            if "Volt" in indicator2:
                parts2 = indicator2.split("Volt")[0].strip()
                if parts2:
                    v2 = float(parts2) if parts2.replace(".", "", 1).replace("-", "", 1).isdigit() else 0.0
            
            if v1 > 4.0 and v2 > 1.0:
                sensor_vals = sensor_values.get(sensor_idx + 1, ["0", "0"])
                sensor_val_str = sensor_vals[1] if len(sensor_vals) > 1 else "0"
                temp = 0.0
                if sensor_val_str.replace(".", "", 1).replace("-", "", 1).isdigit():
                    temp = float(sensor_val_str) / 10.0
                
                discovered.append({
                    "item": "Sensor " + str(sensor_idx + 1),
                    "params": {"levels": (30.0, 35.0)},
                    "metrics": ["temperature"]
                })
        
        return {"changed": False, "msg": "discovered %d sensors" % len(discovered),
                "data": {"discovery": discovered}}
    
    # Check mode: single item
    item = params.get("item", "")
    
    indicator_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_indicator + ".2"
    ], mutates=False)
    
    sensor_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_sensor
    ], mutates=False)
    
    if indicator_res.rc != 0 or sensor_res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    indicator_lines = indicator_res.stdout.strip().splitlines() if indicator_res.stdout.strip() else []
    sensor_lines = sensor_res.stdout.strip().splitlines() if sensor_res.stdout.strip() else []
    
    sensor_values = {}
    for line in sensor_lines:
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        numeric = ""
        for ch in oid_part[::-1]:
            if ch.isdigit():
                numeric = ch + numeric
            elif ch == '.':
                break
        idx = int(numeric) if numeric else 0
        
        if value_part.startswith("STRING: "):
            value_str = value_part[8:].strip()
        elif value_part.startswith("INTEGER: "):
            value_str = value_part[9:].strip()
        else:
            value_str = value_part
        
        if idx not in sensor_values:
            sensor_values[idx] = []
        sensor_values[idx].append(value_str)
    
    # Extract sensor index from item
    sensor_ind = None
    if item.startswith("Sensor "):
        suffix = item.split("Sensor ")[1]
        if suffix.isdigit():
            sensor_ind = int(suffix) - 1
    
    found = False
    temp_val = 0.0
    num_sensors = len(indicator_lines) // 2
    
    for sensor_idx in range(num_sensors):
        indicator1 = sensor_values.get(2 * sensor_idx + 1, [""])[0] if (2 * sensor_idx + 1) in sensor_values else ""
        indicator2 = sensor_values.get(2 * sensor_idx + 2, [""])[0] if (2 * sensor_idx + 2) in sensor_values else ""
        
        v1 = 0.0
        v2 = 0.0
        if "Volt" in indicator1:
            parts1 = indicator1.split("Volt")[0].strip()
            if parts1:
                v1 = float(parts1) if parts1.replace(".", "", 1).replace("-", "", 1).isdigit() else 0.0
        
        if "Volt" in indicator2:
            parts2 = indicator2.split("Volt")[0].strip()
            if parts2:
                v2 = float(parts2) if parts2.replace(".", "", 1).replace("-", "", 1).isdigit() else 0.0
        
        if v1 > 4.0 and v2 > 1.0:
            sensor_vals = sensor_values.get(sensor_idx + 1, ["0", "0"])
            sensor_val_str = sensor_vals[1] if len(sensor_vals) > 1 else "0"
            temp = 0.0
            if sensor_val_str.replace(".", "", 1).replace("-", "", 1).isdigit():
                temp = float(sensor_val_str) / 10.0
            
            if sensor_idx + 1 == sensor_ind:
                found = True
                temp_val = temp
                break
    
    levels = params.get("levels", (30.0, 35.0))
    warn, crit = levels[0], levels[1]
    
    if not found:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if temp_val >= crit:
        state = "CRIT"
    elif temp_val >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Temperature: %f C" % temp_val
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": temp_val}, "details": ""}}