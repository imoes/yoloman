# Starlark check module for W&T WebIO device
# Read-only: gathers SNMP data and reports device input states


# SNMP base OIDs for each WebIO variant
_EA12x12_BASE = ".1.3.6.1.4.1.5040.1.2.4"
_EA12x6_BASE = ".1.3.6.1.4.1.5040.1.2.51"
_EA2x2_BASE = ".1.3.6.1.4.1.5040.1.2.52"

# OIDs to fetch (relative to base)
_OIDS_TO_FETCH = [
    "3.1.1.1.0",  # device description
    "1.3.1.1",    # input port index
    "3.2.1.1.1",  # input description
    "1.3.1.4",    # input state
]

# State translation mapping
_STATE_TRANSLATION = {
    "0": "Off",
    "1": "On",
    "": "Unknown",
}

# Default state evaluation
_DEFAULT_STATE_EVALUATION = {
    "Off": 2,     # CRIT
    "On": 0,      # OK
    "Unknown": 3, # UNKNOWN
}

# Parameter keys
_STATE_EVAL_KEY = "evaluation_mode"
_AS_DISCOVERED = "as_discovered"
_STATES_DURING_DISC_KEY = "states_during_discovery"


def _parse_snmp_output(stdout):
    """Parse SNMP output lines into structured data."""
    lines = stdout.splitlines() if stdout else []
    inputs = []
    
    # Process each line - group by OID prefix
    current_group = {}
    last_oid_prefix = ""
    
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        
        # Format: "OID = TYPE: value"
        eq_pos = stripped.find("=")
        if eq_pos == -1:
            continue
        
        oid_part = stripped[:eq_pos].strip()
        value_part = stripped[eq_pos + 1:].strip()
        
        # Extract value (after ": " in "TYPE: value")
        colon_pos = value_part.find(": ")
        if colon_pos != -1:
            value = value_part[colon_pos + 2:].strip()
        else:
            value = value_part
        
        # Extract index from OID to identify field type
        # Format: base.OID_INDEX
        last_dot = oid_part.rfind(".")
        if last_dot == -1:
            continue
        oid_suffix = oid_part[last_dot + 1:]
        
        # Track groups by tracking consecutive entries with same base
        if oid_suffix == "0":
            # New record starting - save previous if exists
            if current_group and len(current_group) >= 4:
                inputs.append(current_group.copy())
            current_group = {}
        
        # Store by OID suffix
        current_group[oid_suffix] = value
    
    # Save final group
    if current_group and len(current_group) >= 4:
        inputs.append(current_group.copy())
    
    return inputs


def main(ctx, params):
    # Discover mode
    if params.get("_discover"):
        # Try all possible base OIDs to find active WebIO device
        base_oids = [_EA12x6_BASE, _EA2x2_BASE, _EA12x12_BASE]
        all_inputs = {}
        
        for base_oid in base_oids:
            # Build full OID list for this section
            full_oids = [base_oid + "." + oid for oid in _OIDS_TO_FETCH]
            
            # Fetch with snmpwalk (batch mode)
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"),
                ",".join(full_oids)
            ], mutates=False)
            
            if res.rc != 0 or not res.stdout:
                continue
            
            parsed = _parse_snmp_output(res.stdout)
            
            # Process each input record
            for record in parsed:
                # Extract values
                desc_val = record.get("0", "")
                idx_val = record.get("1", "")
                port_desc_val = record.get("2", "")
                state_val = record.get("3", "")
                
                # Build key from description and port description
                key = (desc_val + " " + port_desc_val).strip()
                if not key:
                    key = idx_val
                
                # Skip if empty
                if not key:
                    continue
                
                # Translate state
                state = _STATE_TRANSLATION.get(state_val, "Unknown")
                
                all_inputs[key] = {
                    "state": state,
                    "idx": idx_val
                }
        
        # Build discovery result
        discovery = []
        for item, data in all_inputs.items():
            discovery.append({
                "item": item,
                "params": {
                    _STATES_DURING_DISC_KEY: data["state"]
                },
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d inputs" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode (single item)
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Gather data (reusing same fetch logic)
    base_oids = [_EA12x6_BASE, _EA2x2_BASE, _EA12x12_BASE]
    all_inputs = {}
    
    for base_oid in base_oids:
        full_oids = [base_oid + "." + oid for oid in _OIDS_TO_FETCH]
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ",".join(full_oids)
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout:
            continue
        
        parsed = _parse_snmp_output(res.stdout)
        
        # Build mapping of items to data
        for record in parsed:
            desc_val = record.get("0", "")
            idx_val = record.get("1", "")
            port_desc_val = record.get("2", "")
            state_val = record.get("3", "")
            
            key = (desc_val + " " + port_desc_val).strip()
            if not key:
                key = idx_val
            
            if not key:
                continue
            
            state = _STATE_TRANSLATION.get(state_val, "Unknown")
            
            all_inputs[key] = {
                "state": state,
                "idx": idx_val
            }
    
    # If we can't find the item, return UNKNOWN
    if item not in all_inputs:
        return {
            "changed": False,
            "msg": "input not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    data = all_inputs[item]
    current_state = data["state"]
    
    # Determine state evaluation
    state_map = params.get(_STATE_EVAL_KEY, _DEFAULT_STATE_EVALUATION)
    if state_map == _AS_DISCOVERED:
        discovered_state = params.get(_STATES_DURING_DISC_KEY, "On")
        state_map = {
            "Off": 2 if discovered_state != "Off" else 0,
            "On": 0 if discovered_state == "On" else 2,
            "Unknown": 3
        }
    
    # Map state to Checkmk state
    state_value = state_map.get(current_state, 3)
    state_names = {0: "OK", 2: "CRIT", 3: "UNKNOWN"}
    state_str = state_names.get(state_value, "UNKNOWN")
    
    return {
        "changed": False,
        "msg": "Input (Index: " + data["idx"] + ") is in state: " + current_state,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }