def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        
        # Fetch name branch
        name_res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-On",
            host,
            base_oid + ".10.1.2.1.5303"
        ], mutates=False)
        
        # Fetch value branch
        value_res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-On",
            host,
            base_oid + ".20.1.2.1.5303"
        ], mutates=False)
        
        # Fetch unit branch
        unit_res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-On",
            host,
            base_oid + ".30.1.2.1.5303"
        ], mutates=False)
        
        # Extract position index from name OID
        position_index = None
        item_name = ""
        for line in name_res.stdout.splitlines():
            if "=" not in line:
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_str = parts[0].strip()
            name_val = parts[1].strip().strip('"')
            suffix = oid_str[len(base_oid + ".10.1.2."):]
            if "." in suffix:
                parts_suffix = suffix.split(".")
                if len(parts_suffix) > 0 and parts_suffix[0].isdigit():
                    position_index = int(parts_suffix[0])
                    item_name = name_val
                    break
        
        # Build discovery list if Free Cooling item exists
        discovered = []
        if item_name.startswith("Free Cooling"):
            # Try to get value and unit
            value = None
            unit = ""
            
            for line in value_res.stdout.splitlines():
                if "=" not in line:
                    continue
                parts = line.strip().split(" = ", 1)
                if len(parts) != 2:
                    continue
                val_str = parts[1].strip()
                if val_str.replace(".", "").replace("-", "").isdigit():
                    value = float(val_str) if "." in val_str else int(val_str)
                    break
            
            for line in unit_res.stdout.splitlines():
                if "=" not in line:
                    continue
                parts = line.strip().split(" = ", 1)
                if len(parts) != 2:
                    continue
                unit = parts[1].strip().strip('"')
                break
            
            discovered.append({
                "item": item_name,
                "params": {"min_capacity": (90.0, 80.0)},
                "metrics": ["capacity_perc"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d Free Cooling items" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode: single item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    
    # Get name to find position index
    name_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host,
        base_oid + ".10.1.2.1.5303"
    ], mutates=False)
    
    position_index = None
    for line in name_res.stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_str = parts[0].strip()
        name_val = parts[1].strip().strip('"')
        if name_val == item:
            suffix = oid_str[len(base_oid + ".10.1.2."):]
            if "." in suffix:
                parts_suffix = suffix.split(".")
                if len(parts_suffix) > 0 and parts_suffix[0].isdigit():
                    position_index = int(parts_suffix[0])
                    break
    
    if position_index == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get value and unit for this position
    value_oid = base_oid + ".20.1.2." + str(position_index)
    unit_oid = base_oid + ".30.1.2." + str(position_index)
    
    value_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host,
        value_oid
    ], mutates=False)
    
    unit_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host,
        unit_oid
    ], mutates=False)
    
    # Extract value
    value = None
    for line in value_res.stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        val_str = parts[1].strip()
        if val_str.replace(".", "").replace("-", "").isdigit():
            value = float(val_str) if "." in val_str else int(val_str)
            break
    
    # Extract unit
    unit = ""
    for line in unit_res.stdout.splitlines():
        if "=" not in line:
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        unit = parts[1].strip().strip('"')
        break
    
    if value == None:
        return {
            "changed": False,
            "msg": "unable to retrieve value for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get thresholds
    min_capacity = params.get("min_capacity")
    state = "OK"
    if min_capacity != None:
        if isinstance(min_capacity, tuple) and len(min_capacity) >= 2:
            warn_val = min_capacity[0]
            crit_val = min_capacity[1]
            if value <= crit_val:
                state = "CRIT"
            elif value <= warn_val:
                state = "WARN"
    
    # Format output
    render_val = "%f %s" % (value, unit) if unit else "%f" % value
    msg = "%s %s" % (item, render_val)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"capacity_perc": value},
            "details": ""
        }
    }