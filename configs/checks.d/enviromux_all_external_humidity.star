def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.3699.1.1.11.1.21.1.1"
    
    if params.get("_discover"):
        oids_map = {
            "idx": base_oid + ".1",
            "type": base_oid + ".3",
            "desc": base_oid + ".4",
            "value": base_oid + ".8",
            "min": base_oid + ".10",
            "max": base_oid + ".11",
        }
        
        results = {}
        for key, oid in oids_map.items():
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), oid
            ], mutates=False)
            if res.rc != 0:
                return {"changed": False, "msg": "snmpwalk failed for " + key,
                        "data": {"discovery": []}}
            results[key] = res.stdout.splitlines()
        
        idx_values = {}
        type_values = {}
        desc_values = {}
        value_values = {}
        min_values = {}
        max_values = {}
        
        for line in results["idx"]:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, val = parts
            suffix = oid_full.rsplit(".", 1)[-1]
            is_int = True
            for c in suffix:
                if c < '0' or c > '9':
                    is_int = False
            if not is_int:
                continue
            idx_num = int(suffix)
            idx_values[idx_num] = val.split(": ", 1)[-1].strip().strip('"')
        
        for line in results["type"]:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, val = parts
            suffix = oid_full.rsplit(".", 1)[-1]
            is_int = True
            for c in suffix:
                if c < '0' or c > '9':
                    is_int = False
            if not is_int:
                continue
            idx_num = int(suffix)
            type_values[idx_num] = val.split(": ", 1)[-1].strip().strip('"')
        
        for line in results["desc"]:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, val = parts
            suffix = oid_full.rsplit(".", 1)[-1]
            is_int = True
            for c in suffix:
                if c < '0' or c > '9':
                    is_int = False
            if not is_int:
                continue
            idx_num = int(suffix)
            desc_values[idx_num] = val.split(": ", 1)[-1].strip().strip('"')
        
        for line in results["value"]:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, val = parts
            suffix = oid_full.rsplit(".", 1)[-1]
            is_int = True
            for c in suffix:
                if c < '0' or c > '9':
                    is_int = False
            if not is_int:
                continue
            idx_num = int(suffix)
            value_values[idx_num] = val.split(": ", 1)[-1].strip().strip('"')
        
        for line in results["min"]:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, val = parts
            suffix = oid_full.rsplit(".", 1)[-1]
            is_int = True
            for c in suffix:
                if c < '0' or c > '9':
                    is_int = False
            if not is_int:
                continue
            idx_num = int(suffix)
            min_values[idx_num] = val.split(": ", 1)[-1].strip().strip('"')
        
        for line in results["max"]:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, val = parts
            suffix = oid_full.rsplit(".", 1)[-1]
            is_int = True
            for c in suffix:
                if c < '0' or c > '9':
                    is_int = False
            if not is_int:
                continue
            idx_num = int(suffix)
            max_values[idx_num] = val.split(": ", 1)[-1].strip().strip('"')
        
        discovered = []
        for idx in idx_values:
            sensor_type = type_values.get(idx, "")
            if sensor_type == "2":
                desc = desc_values.get(idx, "")
                item_name = desc + " " + str(idx)
                value_str = value_values.get(idx, "")
                
                if value_str == "":
                    continue
                
                # Validate numeric value
                valid_chars = "0123456789.-"
                valid = True
                for c in value_str:
                    if not (c in valid_chars):
                        valid = False
                if not valid:
                    continue
                
                dot_count = value_str.count(".")
                if dot_count > 1:
                    continue
                
                minus_count = value_str.count("-")
                if minus_count > 1:
                    continue
                if minus_count == 1 and value_str[0] != "-":
                    continue
                
                # Parse float using string methods instead of try/except
                # We'll use a helper-like approach by checking format
                # Since we already validated the string, use a manual parse
                # For simplicity, we'll accept any string that passed validation as floatable
                value = float(value_str)  # This is allowed — Starlark supports float() conversion from string
                
                discovered.append({
                    "item": item_name,
                    "params": {},
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovered),
            "data": {"discovery": discovered},
        }
    
    # Check mode
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item provided",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract index from item name
    idx = 0
    parts = item.rsplit(" ", 1)
    if len(parts) == 2:
        last_part = parts[1]
        is_int = True
        for c in last_part:
            if c < '0' or c > '9':
                is_int = False
        if is_int:
            idx = int(last_part)
        else:
            return {"changed": False, "msg": "could not parse sensor index from item",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "could not parse sensor index from item",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Helper to get single OID value
    def get_snmp_value(oid_suffix):
        res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid + "." + oid_suffix + "." + str(idx)
        ], mutates=False)
        if res.rc != 0:
            return None
        line = res.stdout.strip()
        if not line:
            return None
        parts = line.split(" = ")
        if len(parts) < 2:
            return None
        return parts[1].split(": ", 1)[-1].strip().strip('"')
    
    type_val = get_snmp_value("3")
    value_str = get_snmp_value("8")
    
    # Validate type
    if type_val != "2":
        return {"changed": False, "msg": "item is not a humidity sensor",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Validate and parse humidity value
    if value_str == "":
        return {"changed": False, "msg": "sensor value invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    valid_chars = "0123456789.-"
    valid = True
    for c in value_str:
        if not (c in valid_chars):
            valid = False
    if not valid:
        return {"changed": False, "msg": "sensor value invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    dot_count = value_str.count(".")
    if dot_count > 1:
        return {"changed": False, "msg": "sensor value invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    minus_count = value_str.count("-")
    if minus_count > 1:
        return {"changed": False, "msg": "sensor value invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if minus_count == 1 and value_str[0] != "-":
        return {"changed": False, "msg": "sensor value invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    humidity = float(value_str)
    
    # Thresholds from params (Checkmk defaults)
    warn_lower = params.get("levels_lower", [10.0, 9.0])[0]
    crit_lower = params.get("levels_lower", [10.0, 9.0])[1]
    warn_upper = params.get("levels", [15.0, 16.0])[0]
    crit_upper = params.get("levels", [15.0, 16.0])[1]
    
    # Determine state
    state = "OK"
    if humidity <= crit_lower or humidity >= crit_upper:
        state = "CRIT"
    elif humidity <= warn_lower or humidity >= warn_upper:
        state = "WARN"
    
    # Build message
    msg = "Humidity: %f %%" % humidity
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": "",
        },
    }