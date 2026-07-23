def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.30155.2.1.2.1"
        ], mutates=False)
        
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        sensors = []
        current_instance = ""
        descr = ""
        sensortype = ""
        value = ""
        unit = ""
        state = ""
        
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            if not oid_part.startswith(".1.3.6.1.4.1.30155.2.1.2.1."):
                continue
            
            rest = oid_part[len(".1.3.6.1.4.1.30155.2.1.2.1."):].split(".", 1)
            if len(rest) != 2:
                continue
            idx_str = rest[0]
            field_type = rest[1]
            
            if idx_str != current_instance:
                if current_instance != "" and sensortype == "1" and value != "0" and value != "":
                    sensors.append({
                        "item": descr,
                        "params": {"lower": (500, 300), "upper": (8000, 8400)},
                        "metrics": ["rpm"]
                    })
                
                current_instance = idx_str
                descr = ""
                sensortype = ""
                value = ""
                unit = ""
                state = ""
            
            if field_type == "2":
                if value_part.startswith('"') and value_part.endswith('"'):
                    descr = value_part[1:-1]
                else:
                    descr = value_part
            elif field_type == "3":
                if value_part.startswith("INTEGER:"):
                    sensortype = value_part[8:]
                else:
                    sensortype = value_part
            elif field_type == "5":
                if value_part.startswith("STRING:"):
                    value = value_part[7:]
                else:
                    value = value_part
            elif field_type == "6":
                if value_part.startswith("STRING:"):
                    unit = value_part[7:]
                else:
                    unit = value_part
            elif field_type == "7":
                if value_part.startswith("INTEGER:"):
                    state = value_part[8:]
                else:
                    state = value_part
        
        if current_instance != "" and sensortype == "1" and value != "0" and value != "":
            sensors.append({
                "item": descr,
                "params": {"lower": (500, 300), "upper": (8000, 8400)},
                "metrics": ["rpm"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(sensors),
            "data": {"discovery": sensors}
        }
    
    item = params.get("item", "")
    lower_warn = params.get("lower", (500, 300))
    upper_warn = params.get("upper", (8000, 8400))
    lower_crit = lower_warn[0]
    lower_warn_val = lower_warn[1]
    upper_warn_val = upper_warn[0]
    upper_crit = upper_warn[1]
    
    res_walk = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.30155.2.1.2.1"
    ], mutates=False)
    
    if res_walk.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res_walk.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    target_idx = None
    for line in res_walk.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        if not oid_part.startswith(".1.3.6.1.4.1.30155.2.1.2.1.2."):
            continue
        
        rest = oid_part[len(".1.3.6.1.4.1.30155.2.1.2.1.2."):].strip()
        if value_part.startswith('"') and value_part.endswith('"'):
            descr = value_part[1:-1]
        else:
            descr = value_part
        
        if descr == item:
            parts_oid = oid_part.split(".")
            if len(parts_oid) >= 10:
                target_idx = parts_oid[-1]
            break
    
    if target_idx == None:
        return {
            "changed": False,
            "msg": "fan item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    res_get = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.30155.2.1.2.1.2." + target_idx,
        ".1.3.6.1.4.1.30155.2.1.2.1.3." + target_idx,
        ".1.3.6.1.4.1.30155.2.1.2.1.5." + target_idx,
        ".1.3.6.1.4.1.30155.2.1.2.1.6." + target_idx,
        ".1.3.6.1.4.1.30155.2.1.2.1.7." + target_idx
    ], mutates=False)
    
    if res_get.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed: " + res_get.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    descr_val = ""
    sensortype_val = ""
    value_val = ""
    
    for line in res_get.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        if oid_part.endswith(".2." + target_idx):
            if value_part.startswith('"') and value_part.endswith('"'):
                descr_val = value_part[1:-1]
            else:
                descr_val = value_part
        elif oid_part.endswith(".3." + target_idx):
            if value_part.startswith("INTEGER:"):
                sensortype_val = value_part[8:]
            else:
                sensortype_val = value_part
        elif oid_part.endswith(".5." + target_idx):
            if value_part.startswith("STRING:"):
                value_val = value_part[7:]
            else:
                value_val = value_part
    
    if sensortype_val != "1":
        return {
            "changed": False,
            "msg": "item is not a fan",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    rpm = 0.0
    if value_val != "":
        rpm = float(value_val)
    
    state = "OK"
    details = ""
    
    if rpm < lower_crit:
        state = "CRIT"
        details = "Fan speed too low: %f RPM" % rpm
    elif rpm < lower_warn_val:
        state = "WARN"
        details = "Fan speed low: %f RPM" % rpm
    elif rpm > upper_crit:
        state = "CRIT"
        details = "Fan speed too high: %f RPM" % rpm
    elif rpm > upper_warn_val:
        state = "WARN"
        details = "Fan speed high: %f RPM" % rpm
    
    if details == "":
        details = "Fan speed: %f RPM" % rpm
    
    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": {"rpm": rpm},
            "details": ""
        }
    }