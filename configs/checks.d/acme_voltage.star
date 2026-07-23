def main(ctx, params):
    # Constants for SNMP OIDs and state mapping
    BASE_OID = ".1.3.6.1.4.1.9148.3.3.1.2.1.1"
    OID_DESCR = ".1.3.6.1.4.1.9148.3.3.1.2.1.1.3"
    OID_VALUE = ".1.3.6.1.4.1.9148.3.3.1.2.1.1.4"
    OID_STATE = ".1.3.6.1.4.1.9148.3.3.1.2.1.1.5"
    
    ACME_ENVIRONMENT_STATES = {
        "1": ("OK", "initial"),
        "2": ("OK", "normal"),
        "3": ("WARN", "minor"),
        "4": ("WARN", "major"),
        "5": ("CRIT", "critical"),
        "6": ("CRIT", "shutdown"),
        "7": ("CRIT", "not present"),
        "8": ("CRIT", "not functioning"),
        "9": ("CRIT", "unknown"),
    }
    
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            OID_DESCR, OID_VALUE, OID_STATE
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        # Parse SNMP output into sections
        lines = res.stdout.splitlines()
        descr_map = {}
        value_map = {}
        state_map = {}
        
        for line in lines:
            if not line.strip():
                continue
            # Format: OID = STRING: value
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            oid = oid_part.strip()
            value = value_part.strip()
            
            # Extract index from OID like .1.3.6.1.4.1.9148.3.3.1.2.1.1.3.1
            # Get the last numeric part
            index = oid.rsplit(".", 1)[-1]
            
            if oid.startswith(OID_DESCR + "."):
                descr_map[index] = value
            elif oid.startswith(OID_VALUE + "."):
                # Clean up value (strip quotes if present)
                value_clean = value.strip('"')
                if value_clean.isdigit():
                    value_map[index] = value_clean
            elif oid.startswith(OID_STATE + "."):
                state_map[index] = value.strip('"')
        
        # Build discovery list: combine entries by index, skip if state == "7"
        discovered = []
        seen_indices = set()
        all_indices = set(descr_map.keys()) | set(value_map.keys()) | set(state_map.keys())
        
        for idx in all_indices:
            # Skip if state is "7" (not present) as in original logic
            if idx in state_map and state_map[idx] == "7":
                continue
            
            if idx in descr_map:
                item = descr_map[idx]
                # Check if we need to create a new item entry
                # Use first available state and value if present
                state = state_map.get(idx, "2")  # default to normal
                value_str = value_map.get(idx, "0")  # default to 0
                
                # Determine state text
                state_info = ACME_ENVIRONMENT_STATES.get(state, ("OK", "unknown"))
                state_text = state_info[1]
                
                # Skip if state is "not present"
                if state == "7":
                    continue
                
                discovered.append({
                    "item": item,
                    "params": {},
                    "metrics": ["voltage"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Find index for this item by walking OID_DESCR and matching description
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, OID_DESCR
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    idx_map = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        descr = parts[1].strip().strip('"')
        idx = oid.rsplit(".", 1)[-1]
        idx_map[descr] = idx
    
    if item not in idx_map:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    idx = idx_map[item]
    
    # Fetch value and state for this index
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        OID_VALUE + "." + idx, OID_STATE + "." + idx
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse snmpget output: typically ".1.3.6.1.4.1.9148.3.3.1.2.1.1.4.1 = INTEGER: 1500"
    values = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        val = parts[1].strip()
        
        # Extract numeric part after last dot
        last_part = oid.rsplit(".", 1)[-1]
        
        # Extract value
        if val.startswith("INTEGER:"):
            values["value"] = val.split(":", 1)[1].strip()
        elif val.startswith("STRING:"):
            values["value"] = val.split(":", 1)[1].strip().strip('"')
        elif val.isdigit():
            values["value"] = val
    
    # Fetch description to confirm item
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, OID_DESCR + "." + idx
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        val = parts[1].strip()
        # Extract description
        if val.startswith("STRING:"):
            values["descr"] = val.split(":", 1)[1].strip().strip('"')
        else:
            values["descr"] = val.strip().strip('"')
    
    # Check if we have value and state
    if "value" not in values or "descr" not in values:
        return {
            "changed": False,
            "msg": "missing data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch state OID explicitly
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, OID_STATE + "." + idx
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state_val = ""
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        val = parts[1].strip()
        if val.startswith("INTEGER:"):
            state_val = val.split(":", 1)[1].strip()
        elif val.isdigit():
            state_val = val
    
    if not state_val:
        return {
            "changed": False,
            "msg": "missing state data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get state info
    state_info = ACME_ENVIRONMENT_STATES.get(state_val, ("OK", "unknown"))
    state_text = state_info[1]
    
    # Calculate voltage
    voltage = 0.0
    value_str = values.get("value", "")
    if value_str.isdigit():
        voltage = float(value_str) / 1000.0
    else:
        return {
            "changed": False,
            "msg": "invalid voltage value for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check if state is "7" (not present)
    if state_val == "7":
        return {
            "changed": False,
            "msg": "voltage sensor %s not present" % item,
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
    
    # Determine overall state from sensor state (ignore voltage thresholds as per original logic)
    overall_state = state_info[0]
    
    # Build message
    msg = "%s: %f V, Status: %s" % (item, voltage, state_text)
    
    # Return result
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": {"voltage": voltage},
            "details": ""
        }
    }