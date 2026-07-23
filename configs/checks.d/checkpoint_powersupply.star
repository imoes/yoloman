def main(ctx, params):
    # discover mode: enumerate power supplies by walking the SNMP OID
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.2620.1.6.7.9.1.1.1"
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Get both index (1) and status (2) under the same tree for pairing
        # We'll walk index first, then status, then pair them
        index_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        status_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.2620.1.6.7.9.1.1.2"], mutates=False)
        
        # Parse index OIDs: format is ".1.3.6.1.4.1.2620.1.6.7.9.1.1.1.<idx> = STRING: \"<value>\""
        index_map = {}  # index_number -> index_value
        for line in index_res.stdout.splitlines():
            if line.find(" = STRING: ") == -1:
                continue
            oid_part, value_part = line.split(" = STRING: ", 1)
            # Extract last numeric part of OID
            oid_num = oid_part.rsplit(".", 1)[-1].strip()
            index_val = value_part.strip().strip('"')
            if oid_num == "" or oid_num == "":
                continue
            index_map[oid_num] = index_val
        
        # Parse status OIDs: format is ".1.3.6.1.4.1.2620.1.6.7.9.1.1.2.<idx> = STRING: \"<value>\""
        status_map = {}  # index_number -> status_value
        for line in status_res.stdout.splitlines():
            if line.find(" = STRING: ") == -1:
                continue
            oid_part, value_part = line.split(" = STRING: ", 1)
            oid_num = oid_part.rsplit(".", 1)[-1].strip()
            status_val = value_part.strip().strip('"')
            if oid_num != "":
                status_map[oid_num] = status_val
        
        # Combine: for each index that appears in both, emit item with default params
        out = []
        for num in index_map:
            if num in status_map and index_map[num] != "":
                out.append({
                    "item": index_map[num],
                    "params": {
                        "up": 0,
                        "ok": 0,
                        "present": 2,
                        "no_redundancy": 1
                    },
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(out),
            "data": {"discovery": out}
        }
    
    # check mode: verify one power supply item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get status for requested item
    index_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.2620.1.6.7.9.1.1.1"], mutates=False)
    status_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.2620.1.6.7.9.1.1.2"], mutates=False)
    
    # Build mapping: index_name -> status_string
    index_map = {}
    status_map = {}
    
    for line in index_res.stdout.splitlines():
        if line.find(" = STRING: ") == -1:
            continue
        oid_part, value_part = line.split(" = STRING: ", 1)
        oid_num = oid_part.rsplit(".", 1)[-1].strip()
        index_val = value_part.strip().strip('"')
        if oid_num != "":
            index_map[oid_num] = index_val
    
    for line in status_res.stdout.splitlines():
        if line.find(" = STRING: ") == -1:
            continue
        oid_part, value_part = line.split(" = STRING: ", 1)
        oid_num = oid_part.rsplit(".", 1)[-1].strip()
        status_val = value_part.strip().strip('"')
        if oid_num != "":
            status_map[oid_num] = status_val
    
    # Find matching item
    for num in index_map:
        if index_map[num] == item and num in status_map:
            dev_status = status_map[num]
            # Convert status to checkmk param key: replace spaces with underscore, lowercase
            param_key = dev_status.lower().replace(" ", "_")
            
            # Get configured states from params
            up_state = params.get("up", 0)
            ok_state = params.get("ok", 0)
            present_state = params.get("present", 2)
            no_redundancy_state = params.get("no_redundancy", 1)
            
            # Map to checkmk state constants (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN)
            if param_key == "up":
                cmk_state = up_state
            elif param_key == "ok":
                cmk_state = ok_state
            elif param_key == "present":
                cmk_state = present_state
            elif param_key == "no_redundancy":
                cmk_state = no_redundancy_state
            else:
                cmk_state = 2  # default to CRIT if unknown
            
            # Map checkmk state to string
            if cmk_state == 0:
                state_str = "OK"
            elif cmk_state == 1:
                state_str = "WARN"
            elif cmk_state == 2:
                state_str = "CRIT"
            else:
                state_str = "UNKNOWN"
            
            return {
                "changed": False,
                "msg": dev_status,
                "data": {
                    "state": state_str,
                    "metrics": {},
                    "details": ""
                }
            }
    
    # Item not found
    return {
        "changed": False,
        "msg": "power supply not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }
