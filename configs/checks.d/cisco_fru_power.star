def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discover mode
    if params.get("_discover"):
        # Fetch power supply states and currents
        res_states = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.9.9.117.1.1.2.1.2"
        ], mutates=False)
        res_currents = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.9.9.117.1.1.2.1.3"
        ], mutates=False)
        res_names = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.2.1.47.1.1.1.1.7"
        ], mutates=False)
        
        # Parse OID values
        states = {}
        for line in res_states.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].strip().split(".")[-1]
            value = parts[1].strip()
            if value.startswith("INTEGER: "):
                value = value[9:]
            elif value.startswith("Gauge32: "):
                value = value[9:]
            if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                states[oid_end] = int(value)
        
        currents = {}
        for line in res_currents.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].strip().split(".")[-1]
            value = parts[1].strip()
            if value.startswith("INTEGER: "):
                value = value[9:]
            elif value.startswith("Gauge32: "):
                value = value[9:]
            if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
                currents[oid_end] = int(value)
        
        # Parse device names
        names_map = {}
        for line in res_names.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            full_oid = parts[0].strip()
            value = parts[1].strip()
            if value.startswith("STRING: "):
                value = value[8:]
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            oid_end = full_oid.split(".")[-1]
            names_map[oid_end] = value
        
        # Build name map using the logic from the check plugin
        oid_to_name = {}
        grouped = {}
        for oid_end, name in names_map.items():
            if oid_end in states:
                if name not in grouped:
                    grouped[name] = []
                grouped[name].append(oid_end)
        
        for name, oid_ends in grouped.items():
            if len(oid_ends) == 1:
                oid_to_name[name] = oid_ends[0]
            else:
                for i, oid_end in enumerate(oid_ends):
                    oid_to_name["%s-%d" % (name, i + 1)] = oid_end
        
        # Process each FRU
        discovery_items = []
        for name, oid_end in oid_to_name.items():
            state_val = states.get(oid_end)
            current_val = currents.get(oid_end)
            if state_val == None or current_val == None:
                continue
            
            # Check if it's a "real" PSU (state != 0 and current >= 0)
            if state_val == 0 or current_val < 0:
                continue
            
            # Skip discovery for off env other (1) and off admin (3)
            if state_val in (1, 3):
                continue
            
            # Build suggested params
            discovery_items.append({
                "item": name,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    item = params.get("item", "")
    
    # Fetch all necessary data in one go
    res_states = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.9.9.117.1.1.2.1.2"
    ], mutates=False)
    res_currents = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.9.9.117.1.1.2.1.3"
    ], mutates=False)
    res_names = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.2.1.47.1.1.1.1.7"
    ], mutates=False)
    
    # Parse OID values
    states = {}
    for line in res_states.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_end = parts[0].strip().split(".")[-1]
        value = parts[1].strip()
        if value.startswith("INTEGER: "):
            value = value[9:]
        elif value.startswith("Gauge32: "):
            value = value[9:]
        if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
            states[oid_end] = int(value)
    
    currents = {}
    for line in res_currents.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_end = parts[0].strip().split(".")[-1]
        value = parts[1].strip()
        if value.startswith("INTEGER: "):
            value = value[9:]
        elif value.startswith("Gauge32: "):
            value = value[9:]
        if value.isdigit() or (value.startswith("-") and value[1:].isdigit()):
            currents[oid_end] = int(value)
    
    # Parse device names
    names_map = {}
    for line in res_names.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        full_oid = parts[0].strip()
        value = parts[1].strip()
        if value.startswith("STRING: "):
            value = value[8:]
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        oid_end = full_oid.split(".")[-1]
        names_map[oid_end] = value
    
    # Build name map using the logic from the check plugin
    oid_to_name = {}
    grouped = {}
    for oid_end, name in names_map.items():
        if oid_end in states:
            if name not in grouped:
                grouped[name] = []
            grouped[name].append(oid_end)
    
    for name, oid_ends in grouped.items():
        if len(oid_ends) == 1:
            oid_to_name[name] = oid_ends[0]
        else:
            for i, oid_end in enumerate(oid_ends):
                oid_to_name["%s-%d" % (name, i + 1)] = oid_end
    
    # Get item data
    oid_end = oid_to_name.get(item)
    if oid_end == None or oid_end not in states or oid_end not in currents:
        return {
            "changed": False,
            "msg": "FRU not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state_val = states[oid_end]
    current_val = currents[oid_end]
    
    # Check if it's a "real" PSU (state != 0 and current >= 0)
    if state_val == 0 or current_val < 0:
        return {
            "changed": False,
            "msg": "Not a real PSU: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Map state to status
    state_readable = "unexpected (%d)" % state_val
    state_str = "UNKNOWN"
    
    if state_val == 1:
        state_readable = "off env other"
        state_str = "WARN"
    elif state_val == 2:
        state_readable = "on"
        state_str = "OK"
    elif state_val == 3:
        state_readable = "off admin"
        state_str = "WARN"
    elif state_val == 4:
        state_readable = "off denied"
        state_str = "CRIT"
    elif state_val == 5:
        state_readable = "off env power"
        state_str = "CRIT"
    elif state_val == 6:
        state_readable = "off env temp"
        state_str = "CRIT"
    elif state_val == 7:
        state_readable = "off env fan"
        state_str = "CRIT"
    elif state_val == 8:
        state_readable = "failed"
        state_str = "CRIT"
    elif state_val == 9:
        state_readable = "on but fan fail"
        state_str = "WARN"
    elif state_val == 10:
        state_readable = "off cooling"
        state_str = "WARN"
    elif state_val == 11:
        state_readable = "off connector rating"
        state_str = "WARN"
    elif state_val == 12:
        state_readable = "on but inline power fail"
        state_str = "CRIT"
    
    return {
        "changed": False,
        "msg": "Status: " + state_readable,
        "data": {
            "state": state_str,
            "metrics": {"current": current_val},
            "details": "Current: %d A" % current_val
        }
    }

# Define State constants for the check module
State_OK = "OK"
State_WARN = "WARN"
State_CRIT = "CRIT"
State_UNKNOWN = "UNKNOWN"
