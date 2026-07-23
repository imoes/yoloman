def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Detect which device type we're dealing with
        # First check for AKCP_EXP devices (base .1.3.6.1.4.1.3854.2)
        res_exp = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                          ".1.3.6.1.4.1.3854.2"], mutates=False)
        # Check for AKCP_SENSOR2PLUS devices (base .1.3.6.1.4.1.3854.3.* but NOT .1.3.6.1.4.1.3854.2.*)
        res_sp2plus = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                              ".1.3.6.1.4.1.3854.3"], mutates=False)
        
        # Determine OID base based on detection
        if res_exp.rc == 0 and len(res_exp.stdout.strip()) > 0:
            base_oid = ".1.3.6.1.4.1.3854.2.3.14.1"
        elif res_sp2plus.rc == 0 and len(res_sp2plus.stdout.strip()) > 0:
            # Verify it's not an AKCP_EXP device (no .2.* entries)
            res_exp_check = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                                    ".1.3.6.1.4.1.3854.2"], mutates=False)
            if res_exp_check.rc != 0 or len(res_exp_check.stdout.strip()) == 0:
                base_oid = ".1.3.6.1.4.1.3854.3.5.14.1"
            else:
                return {"changed": False, "msg": "could not determine device type",
                        "data": {"discovery": []}}
        else:
            return {"changed": False, "msg": "could not determine device type",
                    "data": {"discovery": []}}
        
        # Get smoke sensor data
        desc_oid = base_oid + ".2"
        status_oid = base_oid + ".6"
        offline_oid = base_oid + ".8"
        
        # Fetch all smoke sensor data via snmpwalk
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        # Parse the walk output into sections
        section = []
        lines = res.stdout.splitlines()
        
        # We need to associate description, status, and offline status by index
        # SNMP walk returns lines like: OID = STRING: "description"
        # or OID = INTEGER: value
        
        # First get all descriptions
        descriptions = {}
        statuses = {}
        offline_states = {}
        
        for line in lines:
            if not line.strip():
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            value = value_part.strip()
            # Remove leading/trailing quotes if present
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            
            # Extract the leaf OID number
            oid_leaf = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
            
            # Determine OID type based on number
            if oid_leaf == "2":
                descriptions[oid_part] = value
            elif oid_leaf == "6":
                statuses[oid_part] = value
            elif oid_leaf == "8":
                offline_states[oid_part] = value
        
        # Now group by common base OID (remove the leaf)
        # Get common bases for descriptions
        for desc_oid_full, desc in descriptions.items():
            base = ".".join(desc_oid_full.split(".")[:-1])
            status = statuses.get(base + ".6", "1")
            offline = offline_states.get(base + ".8", "1")
            
            # Add to section if online
            if offline == "1":
                section.append([desc, status, offline])
        
        # Build discovery output
        out = []
        for line in section:
            item = line[0]
            out.append({"item": item, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d smoke sensors" % len(out),
                "data": {"discovery": out}}
    
    # Check mode
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item required",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Detect device type
    res_exp = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                      ".1.3.6.1.4.1.3854.2"], mutates=False)
    res_sp2plus = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                          ".1.3.6.1.4.1.3854.3"], mutates=False)
    
    if res_exp.rc == 0 and len(res_exp.stdout.strip()) > 0:
        base_oid = ".1.3.6.1.4.1.3854.2.3.14.1"
    elif res_sp2plus.rc == 0 and len(res_sp2plus.stdout.strip()) > 0:
        res_exp_check = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host,
                                ".1.3.6.1.4.1.3854.2"], mutates=False)
        if res_exp_check.rc != 0 or len(res_exp_check.stdout.strip()) == 0:
            base_oid = ".1.3.6.1.4.1.3854.3.5.14.1"
        else:
            return {"changed": False, "msg": "could not determine device type",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    else:
        return {"changed": False, "msg": "could not determine device type",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    desc_oid = base_oid + ".2"
    status_oid = base_oid + ".6"
    offline_oid = base_oid + ".8"
    
    # Get all smoke sensor data
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = []
    lines = res.stdout.splitlines()
    
    descriptions = {}
    statuses = {}
    offline_states = {}
    
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        value = value_part.strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        
        if oid_part.endswith(".2"):
            descriptions[oid_part] = value
        elif oid_part.endswith(".6"):
            statuses[oid_part] = value
        elif oid_part.endswith(".8"):
            offline_states[oid_part] = value
    
    # Build section
    for desc_oid_full, desc in descriptions.items():
        base = ".".join(desc_oid_full.split(".")[:-1])
        status = statuses.get(base + ".6", "1")
        offline = offline_states.get(base + ".8", "1")
        section.append([desc, status, offline])
    
    # Find matching item
    for description, status, online in section:
        if description == item:
            # Check offline status
            if online != "1":
                return {"changed": False, "msg": "sensor is offline",
                        "data": {"state": "CRIT", "metrics": {}, "details": ""}}
            
            # Map status codes to states (from relay_states in source)
            # "1": (2, "no status"),
            # "2": (0, "normal"),
            # "4": (2, "high critical"),
            # "6": (2, "low critical"),
            # "7": (2, "sensor error"),
            # "8": (2, "relay on"),
            # "9": (0, "relay off")
            state_map = {
                "1": ("CRIT", "no status"),
                "2": ("OK", "normal"),
                "4": ("CRIT", "high critical"),
                "6": ("CRIT", "low critical"),
                "7": ("CRIT", "sensor error"),
                "8": ("CRIT", "relay on"),
                "9": ("OK", "relay off"),
            }
            
            if status not in state_map:
                return {"changed": False, "msg": "unknown status: " + status,
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            
            state_str, state_name = state_map[status]
            
            # Translate to Checkmk state names
            checkmk_state = "CRIT" if state_str == "CRIT" else ("OK" if state_str == "OK" else "WARN")
            
            return {"changed": False, "msg": "State: " + state_name,
                    "data": {"state": checkmk_state, "metrics": {}, "details": ""}}
    
    return {"changed": False, "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
