def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    warn = params.get("levels", [700, 730])
    
    if len(warn) != 2:
        fail("levels must be a list/tuple of two integers [warn, crit]")
    warn_val = int(warn[0])
    crit_val = int(warn[1])
    
    base_oid = ".1.3.6.1.4.1.2011.2.25.4.70.20.20.10.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1", base_oid + ".2"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    items_data = []
    power_data = {}
    
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0]
        value_part = parts[1]
        
        # Parse value type and extract numeric value
        value_str = value_part.strip()
        if ":" in value_part:
            colon_pos = value_part.find(":")
            value_type = value_part[:colon_pos]
            value_str = value_part[colon_pos + 1:].strip()
        else:
            value_type = ""
        
        # Extract numeric OID suffix
        suffix = ""
        if oid_part.startswith(base_oid + ".1"):
            suffix = oid_part[len(base_oid + ".1"):]
        elif oid_part.startswith(base_oid + ".2"):
            suffix = oid_part[len(base_oid + ".2"):]
        else:
            continue
        
        if suffix == "":
            continue
        
        # Parse integer value with guard (no try/except)
        int_value = 0
        if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
            int_value = int(value_str)
        else:
            continue
        
        # Collect data
        if oid_part.endswith(".1"):
            # Name
            if suffix not in power_data:
                power_data[suffix] = {"name": "", "power": None}
            power_data[suffix]["name"] = value_str
        elif oid_part.endswith(".2"):
            # Power
            if suffix not in power_data:
                power_data[suffix] = {"name": "", "power": None}
            power_data[suffix]["power"] = int_value
    
    # Build discovery list
    if params.get("_discover"):
        discovery = []
        for suffix, data in power_data.items():
            if data["name"] != "" and data["power"] != None:
                discovery.append({
                    "item": data["name"],
                    "params": {"levels": [700, 730]},
                    "metrics": ["power"]
                })
        return {
            "changed": False,
            "msg": "discovered %d power units" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Find the matching item
    power_value = None
    for suffix, data in power_data.items():
        if data["name"] == item and data["power"] != None:
            power_value = data["power"]
            break
    
    if power_value == None:
        return {
            "changed": False,
            "msg": "no data for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine state based on thresholds
    if power_value >= crit_val:
        state = "CRIT"
    elif power_value >= warn_val:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "Current reading: %d W" % power_value,
        "data": {
            "state": state,
            "metrics": {"power": power_value},
            "details": ""
        }
    }