def main(ctx, params):
    # Constants
    OID_BASE = ".1.3.6.1.4.1.19746.1.1.1.1.1.1"
    OID_INDEX = OID_BASE + ".1"
    OID_NAME = OID_BASE + ".2"
    OID_DESCR = OID_BASE + ".3"
    OID_STATE = OID_BASE + ".4"
    
    STATE_TABLE = {
        "0": ("Absent", "OK"),
        "1": ("OK", "OK"),
        "2": ("Failed", "CRIT"),
        "3": ("Faulty", "CRIT"),
        "4": ("Acnone", "WARN"),
        "99": ("Unknown", "UNKNOWN"),
    }
    
    # Discovery mode
    if params.get("_discover"):
        # Discover power modules via SNMP walk
        # Walk all four OIDs together to get complete rows
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            OID_BASE
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", 
                    "data": {"discovery": []}}
        
        # Parse SNMP output: lines look like ".1.3.6.1.4.1.19746.1.1.1.1.1.1.1.1 = INTEGER: 1"
        # We need to group by index: each index has 4 consecutive OIDs
        lines = res.stdout.splitlines()
        # Group into rows of 4 OIDs
        rows = []
        current_row = []
        for line in lines:
            current_row.append(line)
            if len(current_row) == 4:
                rows.append(current_row)
                current_row = []
        
        discovery = []
        for row in rows:
            # Extract values from each OID in the row
            values = []
            for line in row:
                # Format: OID = TYPE: VALUE
                if " = " in line:
                    parts = line.split(" = ")
                    if len(parts) == 2:
                        value_part = parts[1]
                        # Extract the actual value (e.g., "INTEGER: 1" -> "1")
                        if ":" in value_part:
                            value = value_part.split(":", 1)[1].strip()
                            values.append(value)
            if len(values) >= 4:
                # Values: [index, name, description, state]
                index = values[0]
                name = values[1]
                description = values[2]
                state = values[3]
                item = name + "-" + index
                # For discovery, use empty string for item (single-service check)
                # Actually the check uses item = name-index, but discovery should yield items
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })
        
        return {"changed": False, "msg": "discovered %d power modules" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    
    # SNMP walk for power module data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        OID_BASE
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP output
    lines = res.stdout.splitlines()
    # Group into rows of 4 OIDs per power module
    rows = []
    current_row = []
    for line in lines:
        current_row.append(line)
        if len(current_row) == 4:
            rows.append(current_row)
            current_row = []
    
    # Look for matching item
    for row in rows:
        values = []
        for line in row:
            if " = " in line:
                parts = line.split(" = ")
                if len(parts) == 2:
                    value_part = parts[1]
                    if ":" in value_part:
                        value = value_part.split(":", 1)[1].strip()
                        values.append(value)
        
        if len(values) >= 4:
            index = values[0]
            name = values[1]
            description = values[2]
            state = values[3]
            
            # Build item as "name-index"
            current_item = name + "-" + index
            
            if current_item == item:
                # Found the matching power module
                state_str, state_code = STATE_TABLE.get(state, ("Unknown", "UNKNOWN"))
                
                # Map Checkmk states to Starlark states
                state_map = {
                    "OK": "OK",
                    "WARN": "WARN",
                    "CRIT": "CRIT",
                    "UNKNOWN": "UNKNOWN"
                }
                
                return {
                    "changed": False,
                    "msg": "%s Status %s" % (description, state_str),
                    "data": {
                        "state": state_map.get(state_code, "UNKNOWN"),
                        "metrics": {},
                        "details": ""
                    }
                }
    
    # Item not found
    return {"changed": False, "msg": "power module not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
