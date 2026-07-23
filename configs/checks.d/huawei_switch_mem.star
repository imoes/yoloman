def main(ctx, params):
    # Discover mode: enumerate memory items from SNMP
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Fetch both SNMP trees: entity table and value table
        res_entities = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.2.1.47.1.1.1.1"
        ], mutates=False)
        
        res_values = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1"
        ], mutates=False)
        
        # Parse entity names and their indices
        entities = {}  # index -> name
        for line in res_entities.stdout.splitlines():
            if not line.strip():
                continue
            # Format: .1.3.6.1.2.1.47.1.1.1.1.X = STRING: "name"
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value_part = parts[1].strip()
            # Extract index from OID (last component after last dot)
            idx = oid.rsplit('.', 1)[-1]
            # Strip quotes from STRING: value
            if value_part.startswith('"') and value_part.endswith('"'):
                name = value_part[1:-1]
            else:
                name = value_part
            entities[idx] = name.lower()
        
        # Parse values table: index -> value
        values = {}  # index -> value
        for line in res_values.stdout.splitlines():
            if not line.strip():
                continue
            # Format: .1.3.6.1.4.1.2011.5.25.31.1.1.1.1.X.Y = INTEGER: Z
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value_part = parts[1].strip()
            # Extract index and subindex
            # OID format: base.X.Y where X is entity index, Y is subindex
            if '.' in oid:
                base_and_idx = oid.rsplit('.', 1)[0]
                subidx = oid.rsplit('.', 1)[-1]
                # Extract entity index (X) from base.X
                if '.' in base_and_idx:
                    ent_idx = base_and_idx.rsplit('.', 1)[-1]
                    # Only keep if subindex is '7'
                    if subidx == "7":
                        values[ent_idx] = value_part
        
        # Build items: look for "mpu board" in entity names
        items = []
        stack_member = 0
        last_stack_member_idx = 0
        
        for idx, name in entities.items():
            # Detect stack member boundaries by "mpu board"
            if name.startswith("mpu board"):
                stack_member += 1
                last_stack_member_idx = 0
            
            # Look for "mpu board" entries
            if name.startswith("mpu board"):
                last_stack_member_idx += 1
                # Get value
                value_str = values.get(idx)
                if value_str != None:
                    # Try to convert to float
                    # Guard: check if value_str looks like a number
                    value = None
                    if value_str.lstrip('-').replace('.', '', 1).isdigit():
                        value = float(value_str)
                    if value != None:
                        item_name = str(stack_member)
                        if True:  # multiple entities per member allowed
                            item_name += "/" + str(last_stack_member_idx)
                        items.append({
                            "item": item_name,
                            "params": {"levels": (80.0, 90.0)},
                            "metrics": ["mem_used_percent"]
                        })
        
        return {
            "changed": False,
            "msg": "discovered %d memory items" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: check one specific item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get entity and value tables
    res_entities = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.2.1.47.1.1.1.1"
    ], mutates=False)
    
    res_values = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.2011.5.25.31.1.1.1.1"
    ], mutates=False)
    
    # Parse entity index -> name mapping
    entities = {}
    for line in res_entities.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value_part = parts[1].strip()
        idx = oid.rsplit('.', 1)[-1]
        if value_part.startswith('"') and value_part.endswith('"'):
            name = value_part[1:-1]
        else:
            name = value_part
        entities[idx] = name.lower()
    
    # Parse value index -> value mapping (only for OID ending in .7)
    values = {}
    for line in res_values.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value_part = parts[1].strip()
        # Extract subindex (Y) from OID base.X.Y
        if '.' in oid:
            subidx = oid.rsplit('.', 1)[-1]
            if subidx == "7":
                base_and_idx = oid.rsplit('.', 1)[0]
                if '.' in base_and_idx:
                    ent_idx = base_and_idx.rsplit('.', 1)[-1]
                    values[ent_idx] = value_part
    
    # Reconstruct the item -> value mapping used in discovery
    # We need to find the value for the requested item
    item_found = False
    item_value = None
    
    stack_member = 0
    last_stack_member_idx = 0
    
    for idx, name in entities.items():
        if name.startswith("mpu board"):
            stack_member += 1
            last_stack_member_idx = 0
        
        if name.startswith("mpu board"):
            last_stack_member_idx += 1
            candidate_item_name = str(stack_member)
            if True:  # multiple entities per member
                candidate_item_name += "/" + str(last_stack_member_idx)
            
            if candidate_item_name == item:
                item_found = True
                value_str = values.get(idx)
                if value_str != None:
                    # Guard: check if value_str looks like a number
                    if value_str.lstrip('-').replace('.', '', 1).isdigit():
                        item_value = float(value_str)
    
    # Check levels
    warn = params.get("levels", (80.0, 90.0))
    warn_level = warn[0]
    crit_level = warn[1]
    
    # Determine state
    if not item_found or item_value == None:
        return {
            "changed": False,
            "msg": "memory item '%s' not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state = "OK"
    if item_value >= crit_level:
        state = "CRIT"
    elif item_value >= warn_level:
        state = "WARN"
    
    return {
        "changed": False,
        "msg": "Usage: %f%%" % item_value,
        "data": {
            "state": state,
            "metrics": {"mem_used_percent": item_value},
            "details": ""
        }
    }