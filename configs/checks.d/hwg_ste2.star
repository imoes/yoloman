def main(ctx, params):
    # Constants for SNMP and state mapping (top-level for Starlark)
    OID_BASE = ".1.3.6.1.4.1.21796.4.9.3.1"
    
    # Unit mapping: "1" -> "c", "2" -> "f", "3" -> "k", "4" -> "%"
    UNIT_MAP = {"1": "c", "2": "f", "3": "k", "4": "%"}
    
    # Status mapping: index 0->invalid, 1->normal, 2->out of range low, 3->out of range high, 4->alarm low, 5->alarm high
    STATUS_MAP = {
        "0": "invalid",
        "1": "normal",
        "2": "out of range low",
        "3": "out of range high",
        "4": "alarm low",
        "5": "alarm high"
    }
    
    # Defaults
    DEFAULT_LEVELS = {"levels": (30.0, 35.0)}
    levels = params.get("levels", DEFAULT_LEVELS.get("levels", (30.0, 35.0)))
    warn = float(levels[0])
    crit = float(levels[1])
    
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"),
            OID_BASE
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP query failed", 
                    "data": {"discovery": []}}
        
        # Parse SNMP output: lines like "<OID>.<index> = STRING:<descr>"
        data_by_index = {}
        
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_full = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract index and type from OID: base.type.index
            suffix = oid_full.replace(OID_BASE + ".", "", 1)
            dot_idx = suffix.find(".")
            if dot_idx == -1:
                continue
            type_num = suffix[:dot_idx]
            index = suffix[dot_idx+1:]
            
            if not index.isdigit():
                continue
            
            # Get the value: strip quotes if STRING
            if value_part.startswith("STRING:"):
                value = value_part[7:].strip().strip('"')
            elif value_part.startswith("INTEGER:"):
                value = value_part[8:].strip()
            elif value_part.startswith("Gauge32:"):
                value = value_part[8:].strip()
            elif value_part.startswith("Counter32:"):
                value = value_part[10:].strip()
            else:
                value = value_part
            
            # Store by index and type
            if index not in data_by_index:
                data_by_index[index] = {}
            if type_num in ["1", "2", "3", "4"]:
                data_by_index[index][type_num] = value
        
        # Build discovery items: only if temperature exists and status not invalid/empty
        discovery_items = []
        for index, attrs in data_by_index.items():
            status_name = STATUS_MAP.get(attrs.get("2", ""), "invalid")
            if "3" in attrs and status_name not in ["invalid", ""]:
                # Temperature data exists (type 3)
                discovery_items.append({
                    "item": index,
                    "params": {"levels": (30.0, 35.0)},
                    "metrics": ["temperature"]
                })
        
        return {"changed": False, "msg": "discovered %d sensors" % len(discovery_items),
                "data": {"discovery": discovery_items}}
    
    # Check mode
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item required",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch all OIDs for this specific item index
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"),
        OID_BASE + "." + item
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "SNMP query failed for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse values for this index
    values = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract type number from OID: base.index.type -> type is last component
        suffix = oid_full.replace(OID_BASE + ".", "", 1)
        dot_idx = suffix.find(".")
        if dot_idx == -1:
            continue
        type_num = suffix[:dot_idx]
        value_str = value_part
        
        if value_str.startswith("STRING:"):
            value_str = value_str[7:].strip().strip('"')
        elif value_str.startswith("INTEGER:"):
            value_str = value_str[8:].strip()
        elif value_str.startswith("Gauge32:"):
            value_str = value_str[8:].strip()
        elif value_str.startswith("Counter32:"):
            value_str = value_str[10:].strip()
        
        values[type_num] = value_str
    
    descr = values.get("1", "")
    status_name = STATUS_MAP.get(values.get("2", ""), "invalid")
    current_str = values.get("3", "")
    unit_str = values.get("4", "")
    
    # Parse temperature with guard instead of try/except
    temp = float(current_str) if current_str.isdigit() or (current_str.replace(".", "", 1).isdigit() and current_str.count(".") <= 1) else None
    if current_str.startswith("-") and len(current_str) > 1:
        # Handle negative numbers
        temp_str = current_str[1:]
        if temp_str.isdigit() or (temp_str.replace(".", "", 1).isdigit() and temp_str.count(".") <= 1):
            temp = -float(temp_str) if current_str.count(".") == 0 else -float(temp_str)
    
    # Determine state
    state_readable = status_name
    if temp == None:
        state = "UNKNOWN" if state_readable == "invalid" else "CRIT" if "out of range" in state_readable or "alarm" in state_readable else "OK"
        return {"changed": False, "msg": "Status: %s" % state_readable,
                "data": {"state": state, "metrics": {}, "details": ""}}
    
    # Temperature level checks
    if state_readable in ["invalid", ""]:
        state = "UNKNOWN"
    elif "out of range" in state_readable or "alarm" in state_readable:
        state = "CRIT"
    else:
        state = "OK"
        if temp >= crit:
            state = "CRIT"
        elif temp >= warn:
            state = "WARN"
    
    unit = UNIT_MAP.get(unit_str, "c")
    unit_str_map = {"c": "C", "f": "F", "k": "K"}
    unit_display = unit_str_map.get(unit, unit)
    
    return {"changed": False, "msg": "Temperature: %f %s, Status: %s" % (temp, unit_display, state_readable),
            "data": {"state": state, "metrics": {"temperature": temp}, "details": "Description: %s" % descr}}