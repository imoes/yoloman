def main(ctx, params):
    # Discover mode: enumerate all temperature sensors
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.3699.1.1.12.1.1.1.1"
        
        # Walk the SNMP tree for sensors: index, type, description, value
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid, base_oid + ".2", base_oid + ".3", base_oid + ".4"
        ], mutates=False)
        
        if res.rc != 0:
            # SNMPTree is unreachable; return empty discovery
            return {"changed": False, "msg": "discovered 0 temperature sensors",
                    "data": {"discovery": []}}
        
        # Parse snmpwalk output lines; they come in groups of 4 lines per OID
        # Each group is: .<base>.1.<idx> = INTEGER: <idx>
        #                .<base>.2.<idx> = INTEGER: <type>
        #                .<base>.3.<idx> = STRING: <description>
        #                .<base>.4.<idx> = STRING: <value>
        sensor_map = {}
        lines = res.stdout.splitlines()
        i = 0
        while i < len(lines):
            # Extract index from first line of group
            if ".1." not in lines[i]:
                i += 1
                continue
            parts = lines[i].strip().split()
            if len(parts) < 3:
                i += 1
                continue
            # Extract the numeric index after the last dot in OID
            oid1 = parts[0].strip()
            idx_part = oid1.rsplit(".", 1)[-1]
            if not idx_part.isdigit():
                i += 1
                continue
            idx = idx_part
            
            # Collect next 3 lines for type, description, value
            if i + 3 >= len(lines):
                break
            
            # type
            tparts = lines[i + 1].strip().split()
            if len(tparts) < 3:
                i += 1
                continue
            type_str = tparts[-1].strip('"')
            
            # description
            dparts = lines[i + 2].strip().split()
            if len(dparts) < 3:
                i += 1
                continue
            desc = " ".join(dparts[2:]).strip('"')
            
            # value
            vparts = lines[i + 3].strip().split()
            if len(vparts) < 3:
                i += 1
                continue
            value_str = vparts[-1].strip()
            
            # Only temperature sensors (type 1) are relevant
            if type_str == "1":
                sensor_key = desc if "#" not in desc else desc.split("#")[0]
                sensor_map[idx] = (sensor_key, value_str)
            
            i += 4
        
        discovered_items = []
        seen_keys = []
        for key in sorted(sensor_map.keys()):
            sensor_key = sensor_map[key][0]
            if sensor_key not in seen_keys:
                seen_keys.append(sensor_key)
                discovered_items.append({
                    "item": sensor_key,
                    "params": {"levels": (15.0, 16.0), "levels_lower": (10.0, 9.0)},
                    "metrics": ["temp"]
                })
        
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovered_items),
                "data": {"discovery": discovered_items}}
    
    # Check mode: single item
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item is required",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.3699.1.1.12.1.1.1.1"
    
    # Discover the index corresponding to this description (exact match, or prefix match if '#' present)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid, base_oid + ".2", base_oid + ".3", base_oid + ".4"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    sensor_index = ""
    value_str = ""
    found = False
    
    i = 0
    while i < len(lines):
        if ".1." not in lines[i]:
            i += 1
            continue
        parts = lines[i].strip().split()
        if len(parts) < 3:
            i += 1
            continue
        oid1 = parts[0].strip()
        idx_part = oid1.rsplit(".", 1)[-1]
        if not idx_part.isdigit():
            i += 1
            continue
        idx = idx_part
        
        if i + 3 >= len(lines):
            break
        
        # type
        tparts = lines[i + 1].strip().split()
        if len(tparts) < 3:
            i += 1
            continue
        type_str = tparts[-1].strip('"')
        
        # description
        dparts = lines[i + 2].strip().split()
        if len(dparts) < 3:
            i += 1
            continue
        desc = " ".join(dparts[2:]).strip('"')
        
        # value
        vparts = lines[i + 3].strip().split()
        if len(vparts) < 3:
            i += 1
            continue
        value_str = vparts[-1].strip()
        
        # Match item to description
        if item == desc or desc.find(item) != -1:
            if type_str == "1":
                sensor_index = idx
                found = True
                break
        
        i += 4
    
    if not found:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse value: value_str is in 1/10 units (e.g. "175" means 17.5°C)
    # Check if value_str looks numeric before dividing
    clean_value = value_str.strip()
    is_numeric = clean_value.replace(".", "", 1).replace("-", "", 1).isdigit()
    
    if not is_numeric:
        return {"changed": False, "msg": "sensor value invalid: " + value_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp = float(clean_value) / 10.0
    
    # Thresholds
    levels = params.get("levels", (15.0, 16.0))
    levels_lower = params.get("levels_lower", (10.0, 9.0))
    
    warn_upper = levels[0]
    crit_upper = levels[1]
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]
    
    state = "OK"
    if temp >= crit_upper or temp <= crit_lower:
        state = "CRIT"
    elif temp >= warn_upper or temp <= warn_lower:
        state = "WARN"
    
    details = ""
    if temp >= warn_upper:
        details = "Temperature is above warning threshold"
    elif temp <= warn_lower:
        details = "Temperature is below warning threshold"
    
    return {"changed": False,
            "msg": "Temperature: %f C" % temp,
            "data": {
                "state": state,
                "metrics": {"temp": temp},
                "details": details,
            }}