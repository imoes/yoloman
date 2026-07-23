def main(ctx, params):
    base_oid = ".1.3.6.1.4.1.1271.2.1.4.1.2.1.1"
    
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Fetch CFM service data via SNMP
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid, ".6", ".5"
        ], mutates=False)
        
        if res.rc != 0:
            fail("SNMP query failed: " + res.stderr)
        
        # Parse snmpwalk output: each line is "OID = TYPE: value"
        section = {}
        lines = res.stdout.splitlines()
        
        # Process snmpwalk output
        i = 0
        while i < len(lines):
            # Expect two consecutive lines for service name (oid 6) and oper state (oid 5)
            if i + 1 < len(lines):
                line1 = lines[i]
                line2 = lines[i + 1]
                
                # Check for expected format and parse safely
                if " = STRING: " in line1 and " = INTEGER: " in line2:
                    # Extract name and state using string operations only
                    parts1 = line1.split(" = STRING: ")
                    parts2 = line2.split(" = INTEGER: ")
                    
                    if len(parts1) == 2 and len(parts2) == 2:
                        name = parts1[1].strip().strip('"')
                        state_val = parts2[1].strip()
                        
                        # Only include if we have valid data
                        if name != "" and name != None and state_val != "":
                            # Map state: '1' -> enabled, '2' -> disabled
                            if state_val == "1":
                                oper_state = "enabled"
                            elif state_val == "2":
                                oper_state = "disabled"
                            else:
                                oper_state = "unknown"
                            
                            if oper_state in ["enabled", "disabled"]:
                                section[name] = oper_state
                i += 2
            else:
                i += 1
        
        # Build discovery result
        out = []
        for item, state in section.items():
            out.append({
                "item": item,
                "params": {"discovered_oper_state": state},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d CFM services" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch all data (same as discovery to get current item's state)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid, ".6", ".5"
    ], mutates=False)
    
    if res.rc != 0:
        fail("SNMP query failed: " + res.stderr)
    
    lines = res.stdout.splitlines()
    section = {}
    i = 0
    while i < len(lines):
        if i + 1 < len(lines):
            line1 = lines[i]
            line2 = lines[i + 1]
            
            if " = STRING: " in line1 and " = INTEGER: " in line2:
                parts1 = line1.split(" = STRING: ")
                parts2 = line2.split(" = INTEGER: ")
                
                if len(parts1) == 2 and len(parts2) == 2:
                    name = parts1[1].strip().strip('"')
                    state_val = parts2[1].strip()
                    
                    if name != "" and name != None and state_val != "":
                        if state_val == "1":
                            oper_state = "enabled"
                        elif state_val == "2":
                            oper_state = "disabled"
                        else:
                            oper_state = "unknown"
                        
                        if oper_state in ["enabled", "disabled"]:
                            section[name] = oper_state
            i += 2
        else:
            i += 1
    
    # Check if item exists in section
    if item not in section:
        return {
            "changed": False,
            "msg": "CFM-Service instance not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    current_state = section[item]
    expected_state = params.get("discovered_oper_state", "")
    
    # State comparison logic: OK if match, CRIT otherwise
    if current_state == expected_state:
        state = "OK"
    else:
        state = "CRIT"
    
    return {
        "changed": False,
        "msg": "CFM-Service instance is %s" % current_state,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
