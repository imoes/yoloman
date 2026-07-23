# Constants for SNMP OIDs
BROCADE_MLX_POWER_TREE1_BASE = ".1.3.6.1.4.1.1991.1.1.1.2.1.1"
BROCADE_MLX_POWER_TREE2_BASE = ".1.3.6.1.4.1.1991.1.1.1.2.2.1"

# State mappings
POWER_STATE_NORMAL = "2"
POWER_STATE_FAILURE = "3"
POWER_STATE_OTHER = "1"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Try tree2 first, fall back to tree1 if empty
        res2 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), 
                       "-On", params.get("host", "localhost"), 
                       BROCADE_MLX_POWER_TREE2_BASE + ".2", 
                       BROCADE_MLX_POWER_TREE2_BASE + ".3", 
                       BROCADE_MLX_POWER_TREE2_BASE + ".4"], mutates=False)
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"),
                       BROCADE_MLX_POWER_TREE1_BASE + ".1",
                       BROCADE_MLX_POWER_TREE1_BASE + ".2",
                       BROCADE_MLX_POWER_TREE1_BASE + ".3"], mutates=False)

        # Parse tree2 output
        parsed_tree2 = _parse_snmp_output(res2.stdout, 3)
        parsed_tree1 = _parse_snmp_output(res1.stdout, 3)

        # Use tree2 if it has entries, otherwise tree1
        entries = parsed_tree2 if len(parsed_tree2) > 0 else parsed_tree1
        
        # Build discovery result for power supplies with non-normal state (state != "1")
        discovery_items = []
        for power_id, data in entries.items():
            if data["state"] != POWER_STATE_OTHER:
                discovery_items.append({
                    "item": power_id,
                    "params": {},
                    "metrics": []
                })

        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }

    # Check mode (normal path)
    item = params.get("item", "")
    
    # Run SNMP walk for both trees to find the item
    res2 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), 
                   "-On", params.get("host", "localhost"), 
                   BROCADE_MLX_POWER_TREE2_BASE + ".2", 
                   BROCADE_MLX_POWER_TREE2_BASE + ".3", 
                   BROCADE_MLX_POWER_TREE2_BASE + ".4"], mutates=False)
    res1 = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"),
                   BROCADE_MLX_POWER_TREE1_BASE + ".1",
                   BROCADE_MLX_POWER_TREE1_BASE + ".2",
                   BROCADE_MLX_POWER_TREE1_BASE + ".3"], mutates=False)

    parsed_tree2 = _parse_snmp_output(res2.stdout, 3)
    parsed_tree1 = _parse_snmp_output(res1.stdout, 3)
    
    # Use tree2 if it has entries, otherwise tree1
    section = parsed_tree2 if len(parsed_tree2) > 0 else parsed_tree1
    
    # Get power supply data
    if item not in section:
        return {
            "changed": False,
            "msg": "Power supply %s not found" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    powersupply_data = section[item]
    state = powersupply_data["state"]
    
    # Determine state based on power supply state
    if state == POWER_STATE_NORMAL:
        state_name = "OK"
        summary = "Power supply reports state: normal"
    elif state == POWER_STATE_FAILURE:
        state_name = "CRIT"
        summary = "Power supply reports state: failure"
    elif state == POWER_STATE_OTHER:
        state_name = "UNKNOWN"
        summary = "Power supply reports state: other"
    else:
        state_name = "UNKNOWN"
        summary = "Power supply reports an unknown state (%s)" % state

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_name,
            "metrics": {},
            "details": ""
        }
    }


def _parse_snmp_output(output, num_fields):
    """Parse SNMP walk output into dict of power_id -> {desc, state}."""
    parsed = {}
    
    # Parse each line of the output
    lines = output.splitlines()
    if not lines:
        return parsed

    # Build power_id -> {desc, state} mapping
    # We need to correlate OID index values across the fields
    # Power ID comes from tree1.1 / tree2.2
    # Power description from tree1.2 / tree2.3
    # Power state from tree1.3 / tree2.4
    
    power_ids = {}
    power_descs = {}
    power_states = {}

    for line in lines:
        line = line.strip()
        if not line:
            continue
            
        # Parse OID = TYPE: value
        if "=" not in line:
            continue
            
        oid_part, value_part = line.split("=", 1)
        oid_part = oid_part.strip()
        value_part = value_part.strip()
        
        # Extract value (remove TYPE: prefix if present)
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip()
        else:
            value = value_part
        
        # Extract index from OID
        # OID format: base.oid_index
        base_oid = None
        if BROCADE_MLX_POWER_TREE1_BASE in oid_part:
            base_oid = BROCADE_MLX_POWER_TREE1_BASE
        elif BROCADE_MLX_POWER_TREE2_BASE in oid_part:
            base_oid = BROCADE_MLX_POWER_TREE2_BASE
            
        if base_oid == None:
            continue
        
        # Get relative OID part
        rel_oid = oid_part[len(base_oid):].strip()
        if not rel_oid:
            continue
            
        # Extract index
        parts = rel_oid.split(".")
        if len(parts) < 2:
            continue
            
        # The last part is the index
        index = parts[-1]
        
        # Determine field type (1, 2, 3)
        if rel_oid.startswith(".1") and base_oid == BROCADE_MLX_POWER_TREE1_BASE:
            field_type = 1
        elif rel_oid.startswith(".2") and base_oid == BROCADE_MLX_POWER_TREE2_BASE:
            field_type = 2
        elif rel_oid.startswith(".3") and base_oid == BROCADE_MLX_POWER_TREE1_BASE:
            field_type = 3
        elif rel_oid.startswith(".4") and base_oid == BROCADE_MLX_POWER_TREE2_BASE:
            field_type = 4
        else:
            continue
            
        if field_type == 1:
            power_ids[index] = value
        elif field_type == 2:
            power_ids[index] = value
        elif field_type == 3:
            power_descs[index] = value
        elif field_type == 4:
            power_states[index] = value
    
    # Combine data
    for idx in power_ids:
        if idx in power_states:
            state = power_states[idx]
            # Only include non-normal states
            parsed[power_ids[idx]] = {
                "desc": power_descs.get(idx, ""),
                "state": state
            }

    return parsed
