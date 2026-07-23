# Constants for SNMP OIDs
_VUTLAN_EMS_SMOKE_BASE = ".1.3.6.1.4.1.39052.1.3.1"
_VUTLAN_EMS_SMOKE_NAME_OID = ".1.3.6.1.4.1.39052.1.3.1.7"
_VUTLAN_EMS_SMOKE_VALUE_OID = ".1.3.6.1.4.1.39052.1.3.1.9"

def _parse_snmp_output(output_lines):
    """Parse snmpwalk output lines into dict: name -> state (int)"""
    name_map = {}
    value_map = {}
    
    for line in output_lines:
        stripped = line.strip()
        if not stripped:
            continue
        eq_idx = stripped.find("=")
        if eq_idx == -1:
            continue
        oid_part = stripped[:eq_idx].strip()
        value_part = stripped[eq_idx+1:].strip()
        
        # Extract instance number from OID (last numeric component)
        oid_parts = oid_part.split(".")
        if len(oid_parts) < 2:
            continue
        instance = oid_parts[-1]
        
        # Skip base OID entries without instance
        if not instance.isdigit():
            continue
        
        # Check if this is a name or value OID
        if oid_part.startswith(_VUTLAN_EMS_SMOKE_NAME_OID):
            # It's a name entry
            name_val = value_part.strip('"').strip("'")
            name_map[instance] = name_val
        elif oid_part.startswith(_VUTLAN_EMS_SMOKE_VALUE_OID):
            # It's a value entry
            val_str = value_part
            if val_str.startswith("INTEGER:"):
                val_str = val_str[len("INTEGER:"):].strip()
            if val_str.isdigit():
                value_map[instance] = int(val_str)
    
    # Build final result by combining name_map and value_map
    result = {}
    for instance, name in name_map.items():
        if instance in value_map:
            result[name] = value_map[instance]
    
    return result

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Run snmpwalk to get both name and value OIDs
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Walk the SNMP subtree
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            _VUTLAN_EMS_SMOKE_BASE
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }
        
        # Parse output
        sensors = _parse_snmp_output(res.stdout.splitlines())
        
        # Build discovery list
        discovery_list = []
        for name, state in sensors.items():
            discovery_list.append({
                "item": name,
                "params": {},
                "metrics": ["smoke_detected"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d smoke sensors" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    # Check mode for a specific item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Walk to get all sensors
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        _VUTLAN_EMS_SMOKE_BASE
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed for smoke detector %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output
    sensors = _parse_snmp_output(res.stdout.splitlines())
    
    # Check if item exists
    if item not in sensors:
        return {
            "changed": False,
            "msg": "smoke detector not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get sensor state
    state_val = sensors[item]
    
    # Determine state: 1 = smoke detected (CRIT), 0 = no smoke (OK)
    if state_val == 1:
        check_state = "CRIT"
        summary = "Smoke detected"
    else:
        check_state = "OK"
        summary = "No smoke detected"
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": check_state,
            "metrics": {"smoke_detected": state_val},
            "details": ""
        }
    }