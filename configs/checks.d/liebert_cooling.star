def main(ctx, params):
    # SNMP OID constants
    BASE_OID = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    OID_NAME = ".10.1.2.1.5078"
    OID_VALUE = ".20.1.2.1.5078"
    OID_UNIT = ".30.1.2.1.5078"
    
    # Default thresholds from Checkmk plugin
    min_capacity_warn = params.get("min_capacity", (90.0, 80.0))
    max_capacity = params.get("max_capacity")
    
    # Discover mode: get all items
    if params.get("_discover"):
        # Use snmpwalk to fetch all three OID subtrees
        res_name = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                           "-On", params.get("host", "localhost"), BASE_OID + OID_NAME], mutates=False)
        res_value = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                            "-On", params.get("host", "localhost"), BASE_OID + OID_VALUE], mutates=False)
        res_unit = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"), BASE_OID + OID_UNIT], mutates=False)
        
        # Parse the results
        items = {}
        for line in res_name.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract item name (remove quotes if present)
            item_name = value_part.strip('"')
            if item_name:
                items[item_name] = {"oid_name": oid_part}
        
        # Add value and unit information
        for line in res_value.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Match with name OID to get item name
            for item_name, info in items.items():
                if oid_part.endswith(info["oid_name"].split(".")[-1]):
                    if value_part.isdigit() or (value_part.startswith("-") and value_part[1:].isdigit()):
                        info["value"] = float(value_part)
                    break
        
        for line in res_unit.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Match with name OID to get item name
            for item_name, info in items.items():
                if oid_part.endswith(info["oid_name"].split(".")[-1]):
                    info["unit"] = value_part.strip('"')
                    break
        
        # Build discovery result
        discovery_items = []
        for item_name, info in items.items():
            if "value" in info:
                discovery_items.append({
                    "item": item_name,
                    "params": {"min_capacity": min_capacity_warn, "max_capacity": max_capacity},
                    "metrics": ["capacity_perc"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d cooling units" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode: process one item
    item = params.get("item", "")
    
    # Run snmpwalk for all relevant OIDs
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost"), BASE_OID], mutates=False)
    
    # Parse the output
    lines = res.stdout.splitlines()
    item_name = ""
    value = None
    unit = ""
    
    # Build a mapping from index suffix to (name, value, unit)
    index_map = {}
    current_name = ""
    current_value = None
    current_unit = ""
    current_index = ""
    
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_full = parts[0].strip()
        val = parts[1].strip().strip('"')
        
        # Extract the index part from the OID
        oid_parts = oid_full.split(".")
        if len(oid_parts) < len(BASE_OID.split(".")) + 1:
            continue
        index_suffix = ".".join(oid_parts[len(BASE_OID.split(".")):])
        
        if oid_full.startswith(BASE_OID + OID_NAME):
            # Save previous if complete
            if current_index and current_name:
                if current_value != None:
                    index_map[current_index] = {"name": current_name, "value": current_value, "unit": current_unit}
            # Start new entry
            current_name = val
            current_value = None
            current_unit = ""
            current_index = index_suffix
        elif oid_full.startswith(BASE_OID + OID_VALUE):
            if index_suffix == current_index:
                if val.isdigit() or (val.startswith("-") and val[1:].isdigit()):
                    current_value = float(val)
        elif oid_full.startswith(BASE_OID + OID_UNIT):
            if index_suffix == current_index:
                current_unit = val.strip('"')
    
    # Don't forget the last entry
    if current_index and current_name:
        if current_value != None:
            index_map[current_index] = {"name": current_name, "value": current_value, "unit": current_unit}
    
    # Find the item
    found = False
    for idx, data in index_map.items():
        if data["name"] == item:
            value = data["value"]
            unit = data["unit"]
            item_name = data["name"]
            found = True
            break
    
    # If we didn't find the item, return UNKNOWN
    if not found or value == None:
        return {
            "changed": False,
            "msg": "item '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Apply threshold logic
    state = "OK"
    details = ""
    
    # Check lower levels (min_capacity)
    if min_capacity_warn != None:
        warn_val = min_capacity_warn[0]
        crit_val = min_capacity_warn[1]
        if value <= crit_val:
            state = "CRIT"
            details = "capacity %f is below critical level %f" % (value, crit_val)
        elif value <= warn_val:
            if state != "CRIT":
                state = "WARN"
            if details == "":
                details = "capacity %f is below warning level %f" % (value, warn_val)
    
    # Check upper levels (max_capacity)
    if max_capacity != None:
        warn_val = max_capacity[0]
        crit_val = max_capacity[1]
        if value >= crit_val:
            state = "CRIT"
            details = "capacity %f exceeds critical level %f" % (value, crit_val)
        elif value >= warn_val:
            if state != "CRIT":
                state = "WARN"
            if details == "":
                details = "capacity %f exceeds warning level %f" % (value, warn_val)
    
    # Build message
    msg = "%s: %f %s" % (item_name, value, unit)
    if details:
        msg += ", " + details
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"capacity_perc": value},
            "details": ""
        }
    }