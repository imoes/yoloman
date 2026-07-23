# Module-level constants
DEFAULT_WARN = 50.0
DEFAULT_CRIT = 60.0

def _string_to_celsius(temp_str):
    """Convert temperature string (e.g., '25C') to Celsius float."""
    if temp_str == None or len(temp_str) < 2:
        return 0.0
    unit = temp_str[-1].lower()
    value_str = temp_str[:-1]
    # Guard: ensure value_str is numeric before converting
    if not value_str.replace(".", "").replace("-", "").replace("+", "").isdigit() and value_str != "-" and value_str != "." and value_str != "-." and value_str != "+.":
        return 0.0
    value = float(value_str)
    
    if unit == "c":
        return value
    elif unit == "f":
        return (value - 32) * 5.0 / 9.0
    elif unit == "k":
        return value - 273.15
    else:
        return value

def _get_temp_unitsym(unit):
    """Return unit symbol."""
    if unit == "c":
        return "C"
    elif unit == "f":
        return "F"
    elif unit == "k":
        return "K"
    else:
        return unit.upper()

def main(ctx, params):
    # Discovery mode
    if params.get("_discover") == True:
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        chassis_entries = {}
        
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].split(".")[-1]
            value = parts[1].split(": ", 1)[-1].strip()
            
            # Map OIDs: 2=name, 3=current, 4=max, 5=min, 7=threshold, 8=avg
            if oid_end == "2":
                chassis_name = value.strip('"')
            elif oid_end == "3":
                curr_temp_str = value.strip('"')
            elif oid_end == "4":
                max_temp_str = value.strip('"')
            elif oid_end == "5":
                min_temp_str = value.strip('"')
            elif oid_end == "7":
                threshold_temp_str = value.strip('"')
            elif oid_end == "8":
                avg_temp_str = value.strip('"') if value.strip('"') != "" else None
            else:
                continue
            
            # When we have all data for an entry, add to chassis_entries
            # This simplistic parsing assumes OID order matches the tree structure
            if oid_end == "8":
                item_name = chassis_name + " " + oid_end
                chassis_entries[item_name] = {
                    "name": chassis_name,
                    "curr_temp": _string_to_celsius(curr_temp_str),
                    "max_temp": _string_to_celsius(max_temp_str),
                    "min_temp": _string_to_celsius(min_temp_str),
                    "threshold_temp": _string_to_celsius(threshold_temp_str),
                    "avg_temp": _string_to_celsius(avg_temp_str) if avg_temp_str != None else None,
                    "dev_unit": curr_temp_str[-1].lower() if len(curr_temp_str) > 0 else "c",
                }
        
        discovery_items = []
        for item in chassis_entries:
            chassis = chassis_entries[item]
            discovery_items.append({
                "item": item,
                "params": {"levels": (DEFAULT_WARN, DEFAULT_CRIT)},
                "metrics": ["temperature"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d chassis temperature items" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host,
        ".1.3.6.1.4.1.11.2.14.11.1.2.8.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse the SNMP data for the requested item
    lines = res.stdout.splitlines()
    chassis_data = {}
    
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_end = parts[0].split(".")[-1]
        value = parts[1].split(": ", 1)[-1].strip()
        
        # Map OIDs: 2=name, 3=current, 4=max, 5=min, 7=threshold, 8=avg
        if oid_end == "2":
            chassis_name = value.strip('"')
        elif oid_end == "3":
            curr_temp_str = value.strip('"')
        elif oid_end == "4":
            max_temp_str = value.strip('"')
        elif oid_end == "5":
            min_temp_str = value.strip('"')
        elif oid_end == "7":
            threshold_temp_str = value.strip('"')
        elif oid_end == "8":
            avg_temp_str = value.strip('"') if value.strip('"') != "" else None
        else:
            continue
        
        # When we have all data for an entry, add to chassis_data
        if oid_end == "8":
            item_name = chassis_name + " " + oid_end
            chassis_data[item_name] = {
                "name": chassis_name,
                "curr_temp": _string_to_celsius(curr_temp_str),
                "max_temp": _string_to_celsius(max_temp_str),
                "min_temp": _string_to_celsius(min_temp_str),
                "threshold_temp": _string_to_celsius(threshold_temp_str),
                "avg_temp": _string_to_celsius(avg_temp_str) if avg_temp_str != None else None,
                "dev_unit": curr_temp_str[-1].lower() if len(curr_temp_str) > 0 else "c",
            }
    
    chassis = chassis_data.get(item)
    if chassis == None:
        return {
            "changed": False,
            "msg": "chassis temperature item not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get thresholds
    warn = params.get("levels", (DEFAULT_WARN, DEFAULT_CRIT))
    if isinstance(warn, int) or isinstance(warn, float):
        warn = (warn, params.get("levels_crit", DEFAULT_CRIT))
    warn = float(warn[0])
    crit = float(warn[1]) if isinstance(warn[1], int) or isinstance(warn[1], float) else DEFAULT_CRIT
    
    # Check temperature
    curr_temp = chassis["curr_temp"]
    threshold_temp = chassis["threshold_temp"]
    
    # Determine state using worst device levels handling (default)
    state = "OK"
    if curr_temp >= crit:
        state = "CRIT"
    elif curr_temp >= warn:
        state = "WARN"
    
    # Build metrics
    metrics = {"temperature": curr_temp}
    
    # Build details
    details = "%s: %fC, Max: %fC, Min: %fC" % (
        chassis["name"], curr_temp, chassis["max_temp"], chassis["min_temp"]
    )
    if chassis["avg_temp"] != None:
        details += ", Avg: %fC" % chassis["avg_temp"]
    
    msg = "Temperature %fC" % curr_temp
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }
