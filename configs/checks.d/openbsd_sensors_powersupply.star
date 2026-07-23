def main(ctx, params):
    # Discovery mode: enumerate all powersupply items
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.30155.2.1.2.1"
        
        # Fetch all sensor entries: descr(2), sensortype(3), value(5), unit(6), state(7)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        
        # Parse lines: OID suffix -> value
        entries = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            idx_dot_col = line.find("=")
            if idx_dot_col == -1:
                continue
            oid = line[:idx_dot_col].strip()
            value_part = line[idx_dot_col + 1:].strip()
            # Extract type and value
            if value_part.startswith("STRING:"):
                value = value_part[7:].strip('\"')
            else:
                value = value_part.split(": ", 1)[-1] if ": " in value_part else value_part
            
            # Parse OID to get index and column
            parts = oid.split(".")
            if len(parts) < 10:
                continue
            
            # Replace try/except with guard
            idx_str = parts[-2]
            col_str = parts[-1]
            if not (idx_str.isdigit() or (idx_str.startswith("-") and idx_str[1:].isdigit())):
                continue
            if not (col_str.isdigit() or (col_str.startswith("-") and col_str[1:].isdigit())):
                continue
            
            idx = int(idx_str)
            col = int(col_str)
            
            if idx not in entries:
                entries[idx] = {}
            entries[idx][col] = value
        
        # Map sensor types
        OPENBSD_MAP_TYPE = {
            "0": "temp", "1": "fan", "2": "voltage",
            "9": "indicator", "13": "drive", "21": "powersupply"
        }
        
        # Build list of powersupply items
        discovered = []
        used_descriptions = {}
        for idx, cols in entries.items():
            descr = cols.get(2, "")
            sensortype = cols.get(3, "")
            value = cols.get(5, "")
            unit = cols.get(6, "")
            state = cols.get(7, "")
            
            if sensortype not in OPENBSD_MAP_TYPE:
                continue
            if OPENBSD_MAP_TYPE[sensortype] != "powersupply":
                continue
            
            # Skip zero/invalid values
            if sensortype == "0" and value == "-273.15":
                continue
            if sensortype in ["1", "2"] and value == "0":
                continue
            
            # Guard instead of try/except
            is_zero_float = False
            if sensortype in ["1", "2"]:
                if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                    if float(value) == 0:
                        is_zero_float = True
            if is_zero_float:
                continue
            
            # Handle duplicate descriptions
            base_name = descr
            if base_name == "":
                base_name = "powersupply"
            if base_name in used_descriptions:
                used_descriptions[base_name] += 1
                item_name = "%s/%d" % (base_name, used_descriptions[base_name])
            else:
                used_descriptions[base_name] = 0
                item_name = base_name
            
            discovered.append({
                "item": item_name,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d powersupplies" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode: evaluate one powersupply item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.30155.2.1.2.1"
    
    # Get the specific sensor entry for this item
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse entries
    entries = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        idx_dot_col = line.find("=")
        if idx_dot_col == -1:
            continue
        oid = line[:idx_dot_col].strip()
        value_part = line[idx_dot_col + 1:].strip()
        if value_part.startswith("STRING:"):
            value = value_part[7:].strip('\"')
        else:
            value = value_part.split(": ", 1)[-1] if ": " in value_part else value_part
        
        parts = oid.split(".")
        if len(parts) < 10:
            continue
        
        idx_str = parts[-2]
        col_str = parts[-1]
        if not (idx_str.isdigit() or (idx_str.startswith("-") and idx_str[1:].isdigit())):
            continue
        if not (col_str.isdigit() or (col_str.startswith("-") and col_str[1:].isdigit())):
            continue
        
        idx = int(idx_str)
        col = int(col_str)
        
        if idx not in entries:
            entries[idx] = {}
        entries[idx][col] = value
    
    OPENBSD_MAP_TYPE = {
        "0": "temp", "1": "fan", "2": "voltage",
        "9": "indicator", "13": "drive", "21": "powersupply"
    }
    
    # Find matching item
    found = None
    used_descriptions = {}
    for idx, cols in entries.items():
        descr = cols.get(2, "")
        sensortype = cols.get(3, "")
        value = cols.get(5, "")
        unit = cols.get(6, "")
        state = cols.get(7, "")
        
        if sensortype not in OPENBSD_MAP_TYPE:
            continue
        if OPENBSD_MAP_TYPE[sensortype] != "powersupply":
            continue
        
        # Skip zero/invalid values
        if sensortype == "0" and value == "-273.15":
            continue
        if sensortype in ["1", "2"] and value == "0":
            continue
        
        # Guard instead of try/except
        is_zero_float = False
        if sensortype in ["1", "2"]:
            if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                if float(value) == 0:
                    is_zero_float = True
        if is_zero_float:
            continue
        
        # Generate item name same as discovery
        base_name = descr if descr else "powersupply"
        if base_name in used_descriptions:
            used_descriptions[base_name] += 1
            current_name = "%s/%d" % (base_name, used_descriptions[base_name])
        else:
            used_descriptions[base_name] = 0
            current_name = base_name
        
        if current_name == item:
            found = {
                "state": state,
                "value": value
            }
            break
    
    if found == None:
        return {"changed": False, "msg": "powersupply item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Map state to Checkmk state
    state_map = {
        "0": "UNKNOWN",
        "1": "OK",
        "2": "WARN",
        "3": "CRIT"
    }
    state = state_map.get(found["state"], "UNKNOWN")
    
    return {
        "changed": False,
        "msg": "Status: " + str(found["value"]),
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }