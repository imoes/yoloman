# Module for Checkmk printer_supply_ricoh translated to Starlark
# Reads Ricoh printer toner supply via SNMP

def _parse_snmp_output(lines):
    """Parse SNMP walk lines into a dict {supply_name: level}."""
    parsed = {}
    for line in lines:
        parts = line.strip().split()
        if len(parts) < 4:
            continue
        # Extract numeric part at end of OID
        oid = parts[0]
        idx_str = oid.rsplit(".", 1)[-1]
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)
        
        # Get value part (after " = ")
        value_part = ""
        for i in range(2, len(parts)):
            if value_part != "":
                value_part += " "
            value_part += parts[i]
        
        # Remove quotes if present
        if value_part.startswith('"') and value_part.endswith('"'):
            value_part = value_part[1:-1]
        
        # Check if this is name line (string) or value line (int)
        if value_part.isdigit() or (value_part.startswith("-") and value_part[1:].isdigit()):
            # It's a value line - store as supply level
            if idx not in parsed:
                parsed[idx] = {}
            parsed[idx]["value"] = int(value_part)
        else:
            # It's a name line - store by index
            # Reverse two-word names if applicable
            words = value_part.split(" ")
            name = value_part
            if len(words) == 2:
                name = words[1] + " " + words[0]
            if idx not in parsed:
                parsed[idx] = {}
            parsed[idx]["name"] = name
    
    # Now pair name and value
    result = {}
    for idx in parsed:
        item = parsed[idx]
        if "name" in item and "value" in item:
            result[item["name"]] = item["value"]
    return result

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.367.3.2.1.2.24.1.1"
    
    # Discovery mode
    if params.get("_discover"):
        # Walk the OID tree to find all supplies
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.367.3.2.1.2.24.1.1.2"
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }
        
        # Collect all supply names
        supplies = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Parse: OID = STRING: "name"
            equals_pos = line.find(" = ")
            if equals_pos == -1:
                continue
            oid_part = line[:equals_pos].strip()
            value_part = line[equals_pos+3:].strip()
            
            # Extract index from OID
            last_dot = oid_part.rfind(".")
            if last_dot == -1:
                continue
            idx_str = oid_part[last_dot+1:]
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            
            # Extract and process name
            if value_part.startswith('"') and value_part.endswith('"'):
                name = value_part[1:-1]
                # Reverse two-word names if applicable
                words = name.split(" ")
                if len(words) == 2:
                    name = words[1] + " " + words[0]
                supplies[name] = idx
        
        # Build discovery items
        discovery_items = []
        for name in supplies:
            discovery_items.append({
                "item": name,
                "params": {"levels": (20.0, 10.0)},
                "metrics": ["supply_toner_other"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d supplies" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode - single item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item is required for check mode",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch all supply data via SNMP walk
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse the SNMP output
    section = _parse_snmp_output(res.stdout.splitlines())
    
    if item not in section:
        return {
            "changed": False,
            "msg": "supply not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get thresholds
    levels = params.get("levels", (20.0, 10.0))
    warn, crit = levels[0], levels[1]
    
    supply_level = section[item]
    
    # Handle negative codes
    if supply_level < 0:
        if supply_level == -100:
            state = "CRIT"
            infotext = "almost empty (<10%)"
            supply_level = 0
        elif supply_level == -2:
            state = "UNKNOWN"
            infotext = "unknown level"
            supply_level = 0
        elif supply_level == -3:
            state = "OK"
            infotext = "100%"
            supply_level = 100
        else:
            state = "OK"
            infotext = "0%"
            supply_level = 0
    else:
        # Regular positive levels
        if supply_level <= crit:
            state = "CRIT"
        elif supply_level <= warn:
            state = "WARN"
        else:
            state = "OK"
        infotext = "%d%%" % supply_level
        
        if state != "OK":
            infotext += " (warn/crit at %f%%/%f%%)" % (warn, crit)
    
    # Determine performance data type
    item_lower = item.lower()
    if "black" in item_lower:
        perf_type = "black"
    elif "cyan" in item_lower:
        perf_type = "cyan"
    elif "magenta" in item_lower:
        perf_type = "magenta"
    elif "yellow" in item_lower:
        perf_type = "yellow"
    else:
        perf_type = "other"
    
    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": {"supply_toner_" + perf_type: supply_level},
            "details": ""
        }
    }