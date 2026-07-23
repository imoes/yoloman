def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Walk PSM plugs section: OID .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.*
        # Format: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.<n> = STRING: "psm_plugs.<index>"
        # We need to collect all psm_plugs entries with their indices.
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6"], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed for psm_plugs: " + res.stderr)
        
        # Parse snmpwalk output: OID = STRING: "psm_plugs.<index>" -> extract indices
        psm_plug_indices = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            value = parts[1].strip()
            if value.startswith("STRING: ") and value.endswith('"'):
                desc = value[8:-1]  # strip 'STRING: "' and trailing '"'
                if desc.startswith("psm_plugs."):
                    # Extract index part after "psm_plugs."
                    index_part = desc[12:]  # len("psm_plugs.") = 12
                    psm_plug_indices.append(index_part)
        
        # Now for each index, get description and location for proper item naming
        use_desc = params.get("use_sensor_description", False)
        discovery_list = []
        for idx in psm_plug_indices:
            # Get DescName for this index: OID .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.7.<idx> = STRING: "..."
            desc_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.7." + idx
            res_desc = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, desc_oid], mutates=False)
            if res_desc.rc != 0 or not res_desc.stdout.strip():
                # Skip if no description available
                continue
            # Format: OID = STRING: "..."
            value = res_desc.stdout.strip().split(" = ")[1]
            if value.startswith("STRING: ") and value.endswith('"'):
                desc = value[8:-1]
            else:
                continue
            
            # Get Location for this index: OID .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.8.<idx> = STRING: "..."
            loc_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.8." + idx
            res_loc = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, loc_oid], mutates=False)
            location = ""
            if res_loc.rc == 0 and res_loc.stdout.strip():
                value_loc = res_loc.stdout.strip().split(" = ")[1]
                if value_loc.startswith("STRING: ") and value_loc.endswith('"'):
                    location = value_loc[8:-1]
            
            # Build item name
            if use_desc:
                # Format: "<location>-<index> <desc>"
                item_name = location + "-" + idx + " " + desc
            else:
                item_name = idx
            
            # Return _item_key for check mode: the raw index
            discovery_list.append({
                "item": item_name,
                "params": {"_item_key": idx},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d psm_plugs" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    # ===== CHECK MODE =====
    # Get item and _item_key
    item = params.get("item", "")
    item_key = params.get("_item_key", item)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch the PSM plug entry status via SNMP
    # Status OID: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.10.<index> = INTEGER: 1=OK, 2=Error
    # But the Python source uses Status field from parsed section, which maps to a string
    # In Checkmk, this maps to INTEGER status where 1=OK, 2=Error, but the summary shows "OK"/"Error"
    
    # Get DescName to verify entry exists
    desc_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.7." + item_key
    res_desc = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, desc_oid], mutates=False)
    if res_desc.rc != 0 or not res_desc.stdout.strip():
        return {
            "changed": False,
            "msg": "PSM plug %s not found" % item_key,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get Status
    status_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.10." + item_key
    res_status = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, status_oid], mutates=False)
    if res_status.rc != 0 or not res_status.stdout.strip():
        return {
            "changed": False,
            "msg": "PSM plug %s not found" % item_key,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse INTEGER status
    status_value = res_status.stdout.strip().split(" = ")[1].strip()
    # Format: INTEGER: 1 or INTEGER: 2
    if status_value.startswith("INTEGER: "):
        status_int = int(status_value[9:])
    else:
        return {
            "changed": False,
            "msg": "PSM plug %s status parse error" % item_key,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Map status_int to state_readable
    if status_int == 1:
        state_readable = "OK"
        state = "OK"
    else:
        state_readable = "Error"
        state = "CRIT"
    
    return {
        "changed": False,
        "msg": "Status: %s" % state_readable,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
