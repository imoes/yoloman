def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Base OID from the Checkmk plugin: .1.3.6.1.2.1.33.1
    base_oid = ".1.3.6.1.2.1.33.1"
    
    # Discovery mode
    if params.get("_discover"):
        # Walk the relevant sub-tree to discover battery temperature entries
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base_oid
        ], mutates=False)
        
        discoveries = []
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            
            # Temperature OID: .1.3.6.1.2.1.33.1.1.5.1.*
            if oid_part.startswith(".1.3.6.1.2.1.33.1.1.5.1."):
                # Extract index
                index = oid_part[30:]
                
                # Extract value
                val_str = ""
                if ": " in value_part:
                    val_str = value_part.split(": ", 1)[1]
                if not val_str.isdigit():
                    continue
                temp_val = int(val_str)
                
                # Skip if temp is 0 (as per Checkmk logic)
                if temp_val == 0:
                    continue
                
                # Try to get corresponding name
                name_oid = ".1.3.6.1.2.1.33.1.1.5.2." + index
                name = ""
                for l in res.stdout.splitlines():
                    l = l.strip()
                    if not l:
                        continue
                    lparts = l.split(" = ", 1)
                    if len(lparts) != 2:
                        continue
                    loid, lvalue = lparts
                    if loid == name_oid:
                        name = lvalue.split(": ", 1)[1].strip('"')
                        break
                
                # Format item as "Battery <name>" or "Battery <index>" if no name
                item = "Battery %s" % (name if name else index)
                discoveries.append({
                    "item": item,
                    "params": {"levels": (40.0, 50.0)},
                    "metrics": ["temp"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d battery temperature sensors" % len(discoveries),
            "data": {"discovery": discoveries}
        }
    
    # Check mode
    item = params.get("item", "")
    # Parse the item name to extract the index (remove "Battery " prefix)
    if item.startswith("Battery "):
        name_part = item[8:]
    else:
        name_part = item
    
    # Look up the temperature for this item
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.2.1.33.1.1.5.1"
    ], mutates=False)
    
    temp_val = None
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        
        # Extract index
        index = oid_part[30:]
        
        # Get corresponding name
        name_oid = ".1.3.6.1.2.1.33.1.1.5.2." + index
        name = ""
        for l in res.stdout.splitlines():
            l = l.strip()
            if not l:
                continue
            lparts = l.split(" = ", 1)
            if len(lparts) != 2:
                continue
            loid, lvalue = lparts
            if loid == name_oid:
                name = lvalue.split(": ", 1)[1].strip('"')
                break
        
        # Check if this matches our item
        expected = "Battery %s" % (name if name else index)
        if expected == item:
            val_str = ""
            if ": " in value_part:
                val_str = value_part.split(": ", 1)[1]
            if val_str.isdigit():
                temp_val = int(val_str)
            break
    
    # If no temperature found, report UNKNOWN
    if temp_val == None:
        return {
            "changed": False,
            "msg": "no battery temperature sensor found: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Get levels
    levels = params.get("levels", (40.0, 50.0))
    warn, crit = levels[0], levels[1]
    
    # Determine state
    if temp_val >= crit:
        state = "CRIT"
    elif temp_val >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Format message
    msg = "Battery temperature: %d C" % temp_val
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"temp": temp_val},
            "details": ""
        }
    }