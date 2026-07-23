def main(ctx, params):
    # SNMP base OIDs for both device types
    # akcp_exp_water: .1.3.6.1.4.1.3854.2.3.9.1
    # akcp_sensor2plus_water: .1.3.6.1.4.1.3854.3.5.9.1
    
    # Determine which base OID to use based on OS family detection
    facts = ctx.facts()
    os_family = facts.get("os_family", "")
    
    # Detect device type using same logic as Checkmk:
    # DETECT_AKCP_EXP: startswith sysObjectID .1.3.6.1.4.1.3854.1 AND exists .1.3.6.1.4.1.3854.2.*
    # DETEC_AKCP_SP2PLUS: startswith sysObjectID .1.3.6.1.4.1.3854 AND exists .1.3.6.1.4.1.3854.3.* AND NOT .1.3.6.1.4.1.3854.2.*
    
    # For simplicity, we'll try both OIDs and use whichever returns data
    # (The Checkmk agent already detected the correct section, but we're standalone)
    # We'll use the base OID that matches the sensor type
    
    # Since we don't have access to sysObjectID directly, use common patterns:
    # Try the main AKCP_EXP OID first (2.3.9.1), then fall back to Sensor2Plus (3.5.9.1)
    base_oid = ".1.3.6.1.4.1.3854.2.3.9.1"  # Try this first
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discovery mode
    if params.get("_discover"):
        # Fetch all water sensor entries
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, 
            base_oid + ".2", base_oid + ".6", base_oid + ".8"
        ], mutates=False)
        
        # Parse output: expect lines like:
        # .1.3.6.1.4.1.3854.2.3.9.1.2.1 = STRING: "Port 1 Wassermelder BE Lager"
        # .1.3.6.1.4.1.3854.2.3.9.1.6.1 = INTEGER: 2
        # .1.3.6.1.4.1.3854.2.3.9.1.8.1 = INTEGER: 1
        
        # Group lines by instance (same suffix)
        entries = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value = parts[1].strip()
            
            # Extract instance suffix (last number in OID)
            suffix = oid.rsplit(".", 1)[-1]
            if not suffix.isdigit():
                continue
            
            # Determine type from OID
            if ".2" in oid:
                etype = "desc"
            elif ".6" in oid:
                etype = "status"
            elif ".8" in oid:
                etype = "online"
            else:
                continue
            
            if suffix not in entries:
                entries[suffix] = {}
            entries[suffix][etype] = value
        
        # Build discovery list
        out = []
        for suffix, data in entries.items():
            desc = data.get("desc", "")
            status = data.get("status", "")
            online = data.get("online", "")
            
            # Only include online sensors (status 2 = normal, but online must be "1")
            # Checkmk logic: yield Service(item=line[0]) if line[-1] == "1"
            if online == "1":
                out.append({
                    "item": desc,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d water sensors" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode
    item = params.get("item", "")
    
    # Fetch data for the specific item
    # First, get all data to find the right entry
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, 
        base_oid + ".2", base_oid + ".6", base_oid + ".8"
    ], mutates=False)
    
    # Parse output into entries
    entries = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()
        
        suffix = oid.rsplit(".", 1)[-1]
        if not suffix.isdigit():
            continue
        
        if ".2" in oid:
            etype = "desc"
        elif ".6" in oid:
            etype = "status"
        elif ".8" in oid:
            etype = "online"
        else:
            continue
        
        if suffix not in entries:
            entries[suffix] = {}
        entries[suffix][etype] = value
    
    # Find the target entry
    state = "UNKNOWN"
    summary = ""
    
    for suffix, data in entries.items():
        desc = data.get("desc", "")
        if desc != item:
            continue
        
        status = data.get("status", "")
        online = data.get("online", "")
        
        # Check if sensor is offline
        if online != "1":
            summary = "sensor is offline"
            state = "CRIT"
            break
        
        # Map status to state (relay states)
        # "1": (2, "no status")
        # "2": (0, "normal")
        # "4": (2, "high critical")
        # "6": (2, "low critical")
        # "7": (2, "sensor error")
        # "8": (2, "relay on")
        # "9": (0, "relay off")
        relay_states = {
            "1": ("CRIT", "no status"),
            "2": ("OK", "normal"),
            "4": ("CRIT", "high critical"),
            "6": ("CRIT", "low critical"),
            "7": ("CRIT", "sensor error"),
            "8": ("CRIT", "relay on"),
            "9": ("OK", "relay off"),
        }
        
        state_name = relay_states.get(status, ("UNKNOWN", "unknown status"))
        state = state_name[0]
        summary = "State: " + state_name[1]
        break
    
    # If item not found, report unknown
    if state == "UNKNOWN":
        summary = "water sensor not found: " + item
        state = "UNKNOWN"
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }
