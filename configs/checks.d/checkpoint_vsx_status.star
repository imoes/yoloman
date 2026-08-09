def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode - get all VS instances
        status_tree_base = ".1.3.6.1.4.1.2620.1.16.22.1.1"
        counter_tree_base = ".1.3.6.1.4.1.2620.1.16.23.1.1"
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Get status data
        status_oids = ["1.1.1.1", "1.1.3.1", "1.1.4.1", "1.1.5.1", "1.1.6.1", "1.1.7.1", "1.1.8.1", "1.1.9.1"]
        status_oid_strings = [status_tree_base + "." + oid for oid in status_oids]
        
        # Get counter data
        counter_oids = ["1.1.2.1", "1.1.4.1", "1.1.5.1", "1.1.6.1", "1.1.7.1", "1.1.8.1", "1.1.9.1", "1.1.10.1", "1.1.11.1", "1.1.12.1"]
        counter_oid_strings = [counter_tree_base + "." + oid for oid in counter_oids]
        
        all_oids = status_oid_strings + counter_oid_strings
        
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host] + all_oids, mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        data_map = {}
        for line in lines:
            if "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value = parts[1].strip()
            data_map[oid] = value
        
        # Parse VS instances - need to group by instance index
        # Each instance has 8 status OIDs and 10 counter OIDs
        # OIDs end with .1 for each instance
        
        # Extract instance indices by looking at first status OID
        vs_ids = []
        for oid in data_map:
            if oid.startswith(status_tree_base + ".1.1.1.1."):
                idx = oid.replace(status_tree_base + ".1.1.1.1.", "")
                vs_ids.append(idx)
        
        discovery_items = []
        for idx in vs_ids:
            # Extract values for this instance
            vs_id_val = data_map.get(status_tree_base + ".1.1.1.1." + idx, "")
            vs_name = data_map.get(status_tree_base + ".1.1.3.1." + idx, "")
            vs_type = data_map.get(status_tree_base + ".1.1.4.1." + idx, "")
            vs_ip = data_map.get(status_tree_base + ".1.1.5.1." + idx, "")
            vs_policy = data_map.get(status_tree_base + ".1.1.6.1." + idx, "")
            vs_policy_type = data_map.get(status_tree_base + ".1.1.7.1." + idx, "")
            vs_sic_status = data_map.get(status_tree_base + ".1.1.8.1." + idx, "")
            vs_ha_status = data_map.get(status_tree_base + ".1.1.9.1." + idx, "")
            
            # Remove quotes from string values
            if vs_name.startswith('"') and vs_name.endswith('"'):
                vs_name = vs_name[1:-1]
            if vs_type.startswith('"') and vs_type.endswith('"'):
                vs_type = vs_type[1:-1]
            if vs_ip.startswith('"') and vs_ip.endswith('"'):
                vs_ip = vs_ip[1:-1]
            if vs_policy.startswith('"') and vs_policy.endswith('"'):
                vs_policy = vs_policy[1:-1]
            if vs_policy_type.startswith('"') and vs_policy_type.endswith('"'):
                vs_policy_type = vs_policy_type[1:-1]
            if vs_sic_status.startswith('"') and vs_sic_status.endswith('"'):
                vs_sic_status = vs_sic_status[1:-1]
            if vs_ha_status.startswith('"') and vs_ha_status.endswith('"'):
                vs_ha_status = vs_ha_status[1:-1]
            
            item_name = vs_name.strip() + " " + vs_id_val.strip()
            discovery_items.append({
                "item": item_name,
                "params": {},
                "metrics": []
            })
        
        return {"changed": False, "msg": "discovered %d VS instances" % len(discovery_items),
                "data": {"discovery": discovery_items}}
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    status_tree_base = ".1.3.6.1.4.1.2620.1.16.22.1.1"
    
    # Parse item to extract instance index - item is "<vs_name> <vs_id>"
    parts = item.rsplit(" ", 1)
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item format", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    vs_id = parts[1].strip()
    
    # Get required OIDs for status check
    vs_type_oid = status_tree_base + ".1.1.4.1." + vs_id
    vs_ip_oid = status_tree_base + ".1.1.5.1." + vs_id
    vs_policy_oid = status_tree_base + ".1.1.6.1." + vs_id
    vs_policy_type_oid = status_tree_base + ".1.1.7.1." + vs_id
    vs_sic_status_oid = status_tree_base + ".1.1.8.1." + vs_id
    vs_ha_status_oid = status_tree_base + ".1.1.9.1." + vs_id
    
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, vs_type_oid, vs_ip_oid, 
                   vs_policy_oid, vs_policy_type_oid, vs_sic_status_oid, vs_ha_status_oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP get failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    data_map = {}
    for line in lines:
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()
        data_map[oid] = value
    
    def get_value(oid):
        return data_map.get(oid, "")
    
    # Extract and clean string values
    vs_type = get_value(vs_type_oid)
    if vs_type.startswith('"') and vs_type.endswith('"'):
        vs_type = vs_type[1:-1]
    
    vs_ip = get_value(vs_ip_oid)
    if vs_ip.startswith('"') and vs_ip.endswith('"'):
        vs_ip = vs_ip[1:-1]
    
    vs_policy = get_value(vs_policy_oid)
    if vs_policy.startswith('"') and vs_policy.endswith('"'):
        vs_policy = vs_policy[1:-1]
    
    vs_policy_type = get_value(vs_policy_type_oid)
    if vs_policy_type.startswith('"') and vs_policy_type.endswith('"'):
        vs_policy_type = vs_policy_type[1:-1]
    
    vs_sic_status = get_value(vs_sic_status_oid)
    if vs_sic_status.startswith('"') and vs_sic_status.endswith('"'):
        vs_sic_status = vs_sic_status[1:-1]
    
    vs_ha_status = get_value(vs_ha_status_oid)
    if vs_ha_status.startswith('"') and vs_ha_status.endswith('"'):
        vs_ha_status = vs_ha_status[1:-1]
    
    # Determine state and build message
    state = "OK"
    details_parts = []
    
    # HA Status check
    ha_lower = vs_ha_status.lower()
    if ha_lower not in ["active", "standby"]:
        state = "CRIT"
    details_parts.append("HA Status: " + vs_ha_status)
    
    # SIC Status check
    sic_lower = vs_sic_status.lower()
    if sic_lower != "trust established":
        state = "CRIT"
    details_parts.append("SIC Status: " + vs_sic_status)
    
    # Policy name
    details_parts.append("Policy name: " + vs_policy)
    
    # Policy type check
    pt_lower = vs_policy_type.lower()
    if pt_lower not in ["active", "initial policy"]:
        state = "CRIT"
    if pt_lower not in ["active", "initial policy"]:
        details_parts.append("Policy type: " + vs_policy_type + " (no policy installed)")
    else:
        details_parts.append("Policy type: " + vs_policy_type)
    
    details = ", ".join(details_parts)
    msg = details
    
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {}, "details": ""}}
