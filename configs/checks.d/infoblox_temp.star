def main(ctx, params):
    BASE_STATUS = ".1.3.6.1.4.1.7779.3.1.1.2.1.10.1.2"
    BASE_DESCR = ".1.3.6.1.4.1.7779.3.1.1.2.1.10.1.3"
    INDICES = ["37", "38", "39", "40", "41"]
    
    MAP_STATES = {
        "1": (0, "working"),
        "2": (1, "warning"),
        "3": (2, "failed"),
        "4": (1, "inactive"),
        "5": (3, "unknown"),
    }
    
    if params.get("_discover"):
        res_version = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.7779.3.1.1.2.1.7.0"
        ], mutates=False)
        
        if not res_version.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []}
            }
        
        version_line = res_version.stdout.strip().split("\n")[0]
        use_new_format = False
        if "=" in version_line:
            version_raw = version_line.split()[-1].split(".")
            if len(version_raw) >= 2:
                major_str = version_raw[0]
                minor_str = version_raw[1]
                if major_str.isdigit() and minor_str.isdigit():
                    major_version = int(major_str)
                    minor_version = int(minor_str)
                    use_new_format = major_version > 8 or (major_version == 8 and minor_version > 6)
        
        offset = 0 if use_new_format else 3
        indices_to_use = INDICES[offset:]
        
        res_status = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            BASE_STATUS
        ], mutates=False)
        
        res_descr = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            BASE_DESCR
        ], mutates=False)
        
        status_map = {}
        for line in res_status.stdout.strip().split("\n"):
            if not line:
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].rsplit(".", 1)[-1]
            val_str = parts[1].split(":")[-1].strip() if ":" in parts[1] else ""
            if oid_end in INDICES:
                status_map[oid_end] = val_str
        
        descr_map = {}
        for line in res_descr.stdout.strip().split("\n"):
            if not line:
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].rsplit(".", 1)[-1]
            val_str = parts[1].split(":")[-1].strip() if ":" in parts[1] else ""
            if oid_end in INDICES:
                descr_map[oid_end] = val_str
        
        out = []
        for idx in indices_to_use:
            state_val = status_map.get(idx)
            descr_val = descr_map.get(idx)
            if state_val == None or descr_val == None:
                continue
            
            if ":" not in descr_val:
                continue
            
            name_part, val_str = descr_val.split(":", 1)
            name_map = {
                "37": "cpu1",
                "38": "cpu2",
                "39": "sys",
                "40": "mem",
                "41": "other"
            }
            sensor_name = name_map.get(idx, idx)
            item_name = (name_part.strip() + " " + sensor_name).strip()
            
            out.append({
                "item": item_name,
                "params": {"levels": [40.0, 50.0]},
                "metrics": ["temp"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}
        }
    
    item = params.get("item", "")
    warn = 40.0
    crit = 50.0
    if params.get("levels") != None:
        levels = params.get("levels")
        if type(levels) == "list" and len(levels) >= 2:
            warn = float(levels[0])
            crit = float(levels[1])
        elif type(levels) == "int" or type(levels) == "float":
            warn = float(levels)
            crit = float(levels) * 1.25
    
    res_version = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.7779.3.1.1.2.1.7.0"
    ], mutates=False)
    
    use_new_format = False
    if res_version.stdout.strip():
        version_line = res_version.stdout.strip().split("\n")[0]
        if "=" in version_line:
            version_raw = version_line.split()[-1].split(".")
            if len(version_raw) >= 2:
                major_str = version_raw[0]
                minor_str = version_raw[1]
                if major_str.isdigit() and minor_str.isdigit():
                    major_version = int(major_str)
                    minor_version = int(minor_str)
                    use_new_format = major_version > 8 or (major_version == 8 and minor_version > 6)
    
    offset = 0 if use_new_format else 3
    indices_to_use = INDICES[offset:]
    
    res_status = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        BASE_STATUS
    ], mutates=False)
    
    res_descr = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        BASE_DESCR
    ], mutates=False)
    
    status_map = {}
    for line in res_status.stdout.strip().split("\n"):
        if not line:
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_end = parts[0].rsplit(".", 1)[-1]
        val_str = parts[1].split(":")[-1].strip() if ":" in parts[1] else ""
        if oid_end in INDICES:
            status_map[oid_end] = val_str
    
    descr_map = {}
    for line in res_descr.stdout.strip().split("\n"):
        if not line:
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_end = parts[0].rsplit(".", 1)[-1]
        val_str = parts[1].split(":")[-1].strip() if ":" in parts[1] else ""
        if oid_end in INDICES:
            descr_map[oid_end] = val_str
    
    sensor_reading = None
    sensor_unit = "celsius"
    
    for idx in indices_to_use:
        state_val = status_map.get(idx)
        descr_val = descr_map.get(idx)
        if state_val == None or descr_val == None:
            continue
        
        if ":" not in descr_val:
            continue
        
        name_part, val_str = descr_val.split(":", 1)
        name_map = {
            "37": "cpu1",
            "38": "cpu2",
            "39": "sys",
            "40": "mem",
            "41": "other"
        }
        sensor_name = name_map.get(idx, idx)
        check_item = (name_part.strip() + " " + sensor_name).strip()
        
        if check_item == item:
            parts_val = val_str.strip().split()
            if len(parts_val) >= 2:
                r_val = parts_val[0]
                unit = parts_val[1]
                # Guard against non-numeric string
                clean_r_val = r_val.replace(".", "").replace("-", "")
                if clean_r_val.isdigit():
                    sensor_reading = float(r_val)
                    sensor_unit = unit.lower()
            break
    
    if sensor_reading == None:
        return {
            "changed": False,
            "msg": "sensor not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state = "OK"
    if sensor_reading >= crit:
        state = "CRIT"
    elif sensor_reading >= warn:
        state = "WARN"
    
    msg = "Temperature: %f C" % sensor_reading
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": sensor_reading},
            "details": ""
        }
    }