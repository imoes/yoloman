# Module-level constants for state mapping
STATE_MAPPING = {
    "OK": "OK",
    "Off": "OK",
    "On": "WARN",
    "Open": "WARN",
    "Closed": "OK",
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: get CMCIII data via SNMP
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Base OIDs for CMCIII IO sensors
        # .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6 is the base for Air.Temperature.DescName
        # We need to discover the IO section specifically
        # Checkmk agent uses .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.* for IO sensors
        # Get the table of IO sensors
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
        ], mutates=False)
        
        # Parse discovery
        out = []
        for line in res.stdout.splitlines():
            if line.strip() == "":
                continue
            # Format: OID = STRING: value or OID = INTEGER: value
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract item key from OID
            # The OID ends with .index, so we extract that
            # e.g., .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.2.1.1 = STRING: "Relay.1.Status"
            # We want to extract "Relay.1" or just use the index
            # For simplicity, we'll use the last numeric component as item
            oid_parts = oid_part.split(".")
            if len(oid_parts) >= 1 and oid_parts[-1].isdigit():
                item_key = oid_parts[-1]
                # Create a simple item name (we'll use item_key directly)
                # For discovery, we'll use the key as item
                out.append({"item": item_key, "params": {}, "metrics": ["status"]})
        
        return {"changed": False, "msg": "discovered %d IO sensors" % len(out),
                "data": {"discovery": out}}
    
    # Check mode: verify a specific item
    item = params.get("item", "")
    
    # Gather data via SNMP - get all IO sensor data
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get status OID for the item - use .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.*
    # We need the base OID for all IO sensors
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
    ], mutates=False)
    
    # Parse to find our item
    entry = None
    for line in res.stdout.splitlines():
        if line.strip() == "":
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract item key from OID
        oid_parts = oid_part.split(".")
        if len(oid_parts) >= 1 and oid_parts[-1].isdigit():
            item_key = oid_parts[-1]
            if item_key == item:
                # Found our item - need to get more details
                # Get status and other fields
                # We'll extract the status from this line - but need to get other fields
                # For now, note we found it - we'll process below
                # Actually, we need to get specific fields - use a different approach
                pass
    
    # Better approach: walk all relevant OIDs for the item
    # We need to construct OIDs for Status, Logic, Delay, Relay
    # Base for Status: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.X.1.1 where X is item index
    # Let's walk the entire IO section with more detail
    
    # We'll use a more direct approach - get all data we need
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"
    ], mutates=False)
    
    # Parse the entire response
    # Structure: each sensor has multiple fields: .1.Status, .2.Logic, etc.
    sensors = {}
    current_sensor_id = None
    for line in res.stdout.splitlines():
        if line.strip() == "":
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract sensor ID and field type from OID
        # OID format: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.X.Y.Z
        # X = sensor index, Y = field group, Z = field type
        # For simplicity, extract just the sensor index from the last number before the value
        oid_tokens = oid_part.split(".")
        # The pattern is ...6.X.1.1 for Status, etc.
        # Find the sensor index (the number right after the base)
        if len(oid_tokens) >= 12 and oid_tokens[-2].isdigit():
            # Get sensor ID from the index after the base
            base_idx = 12  # approximate position
            if base_idx < len(oid_tokens):
                # We need to find the position after .6.
                # Let's assume the structure is consistent
                pass
        
        # Simpler: look for the pattern .6.1.1 at the end which indicates Status
        # But we need to extract the sensor index
        # Let's try: find the last numeric segment before the field spec
        # We'll use a heuristic: split by dots and find the index
        parts_list = oid_part.split(".")
        # Find the position of "6" (should be at position -8 in standard OID)
        # We'll just use the last number before the last two numbers
        if len(parts_list) > 2:
            # The sensor index is the second to last numeric in the specific part
            # Let's just assume: .6.X.Y.Z where X is sensor ID
            # For OIDs like .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.1.1.1
            # The sensor ID is 1, the next number is 1, then 1
            # We'll extract sensor_id = parts_list[-3] if pattern matches
            if parts_list[-4] == "6":
                sensor_id = parts_list[-3]
                # Get field name based on last number
                # We'll need to map: 1 -> Status, 2 -> Logic, etc.
                field_num = int(parts_list[-1])
                # Map field numbers to names
                field_map = {1: "Status", 2: "Logic", 3: "Delay", 4: "Relay"}
                field_name = field_map.get(field_num, "Field" + str(field_num))
                # Extract value - remove quotes if string
                if value_part.startswith('"') and value_part.endswith('"'):
                    value_part = value_part[1:-1]
                
                if sensor_id not in sensors:
                    sensors[sensor_id] = {}
                sensors[sensor_id][field_name] = value_part
    
    # Find our item
    if item in sensors:
        entry = sensors[item]
    else:
        # Try to match by partial item or use item as key directly
        # For compatibility, check if any entry has this item
        found = False
        for sensor_id in sensors:
            # The item might be the sensor_id or a description
            # For simplicity, assume item matches sensor_id
            if sensor_id == item:
                entry = sensors[sensor_id]
                found = True
                break
        
        if not found and len(sensors) > 0:
            # If item is empty, use first entry
            if item == "":
                for sensor_id in sensors:
                    entry = sensors[sensor_id]
                    break
            else:
                return {"changed": False, "msg": "IO sensor not found: " + item,
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if entry == None:
        return {"changed": False, "msg": "IO sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get status
    status = entry.get("Status", "Unknown")
    # Map to Starlark state
    state_val = STATE_MAPPING.get(status, "WARN")
    
    # Build message
    msg = "Status: %s" % status
    
    # Add other fields if present
    details_parts = []
    for key in ["Logic", "Delay", "Relay"]:
        if key in entry:
            details_parts.append("%s: %s" % (key, entry[key]))
    
    # Return result
    return {
        "changed": False,
        "msg": msg + (", " + ", ".join(details_parts) if details_parts else ""),
        "data": {
            "state": state_val,
            "metrics": {},
            "details": "",
        },
    }
