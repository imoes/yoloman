def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Base OID from Checkmk source: .1.3.6.1.4.1.2.3.51.3.1.3.2.1
    base_oid = ".1.3.6.1.4.1.2.3.51.3.1.3.2.1"
    
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        
        fans = []
        descr_map = {}  # index -> descr
        speed_map = {}  # index -> speed_text
        
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract index from OID
            oid_segments = oid_part.split(".")
            if len(oid_segments) < 2:
                continue
            index_str = oid_segments[-1]
            idx = int(index_str) if index_str.isdigit() else -1
            if idx == -1:
                continue
            
            # Check if it's a STRING type
            if value_part.startswith("STRING: "):
                value = value_part[8:]  # Remove "STRING: " prefix
                # Remove surrounding quotes if present
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                # Check if this OID ends with .2 (descr) or .3 (speed)
                if oid_part.endswith(".2." + index_str) or oid_part == base_oid + ".2." + index_str:
                    # This is a description
                    if value.lower() != "offline":
                        descr_map[idx] = value
                elif oid_part.endswith(".3." + index_str) or oid_part == base_oid + ".3." + index_str:
                    # This is speed
                    speed_map[idx] = value
        
        # Build discovery list by matching index
        discovered = []
        for idx in sorted(descr_map.keys()):
            if idx in speed_map:
                speed_text = speed_map[idx]
                if speed_text.lower() != "offline":
                    fan_name = descr_map[idx]
                    discovered.append({
                        "item": fan_name,
                        "params": {"levels": None, "levels_lower": (28.0, 25.0)},
                        "metrics": ["speed_percent"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode for a specific item
    item = params.get("item", "")
    warn_upper = None
    crit_upper = None
    warn_lower = None
    crit_lower = None
    
    levels = params.get("levels")
    if levels != None:
        if type(levels) == "list" and len(levels) == 2:
            warn_upper = levels[0]
            crit_upper = levels[1]
    
    levels_lower = params.get("levels_lower", (28.0, 25.0))
    if type(levels_lower) == "list" and len(levels_lower) == 2:
        warn_lower = levels_lower[0]
        crit_lower = levels_lower[1]
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "snmpwalk failed for fan",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Scan for the requested item
    descr_map = {}  # index -> descr
    speed_map = {}  # index -> speed_text
    
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        oid_segments = oid_part.split(".")
        if len(oid_segments) < 2:
            continue
        index_str = oid_segments[-1]
        idx = int(index_str) if index_str.isdigit() else -1
        if idx == -1:
            continue
        
        if value_part.startswith("STRING: "):
            value = value_part[8:]
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            if oid_part.endswith(".2." + index_str) or oid_part == base_oid + ".2." + index_str:
                descr_map[idx] = value
            elif oid_part.endswith(".3." + index_str) or oid_part == base_oid + ".3." + index_str:
                speed_map[idx] = value
    
    # Find the fan data for the requested item
    found = False
    for idx in descr_map:
        if descr_map[idx] == item:
            found = True
            speed_text = speed_map.get(idx, "unavailable")
            
            # Check for offline/unavailable states
            speed_lower = speed_text.lower()
            if speed_lower == "offline" or speed_lower == "unavailable":
                return {
                    "changed": False,
                    "msg": "is " + speed_lower,
                    "data": {"state": "CRIT", "metrics": {"speed_percent": 0}, "details": ""}
                }
            
            # Parse speed value: "34 %", "34%", "34 % of maximum", or just "34"
            speed_str = speed_text.strip()
            for rep in ['["%]', "%", "of", "maximum"]:
                speed_str = speed_str.replace(rep, " ")
            parts = speed_str.split()
            if len(parts) == 0 or not parts[0].isdigit():
                return {
                    "changed": False,
                    "msg": "could not parse speed",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            
            rpm_perc = int(parts[0])
            
            # Determine state
            state = "OK"
            msg_parts = ["%of max RPM: %d%%" % rpm_perc]
            
            # Upper levels check (if specified)
            if crit_upper != None and rpm_perc >= crit_upper:
                state = "CRIT"
            elif warn_upper != None and rpm_perc >= warn_upper:
                state = "WARN"
            
            # Lower levels check (if specified)
            if crit_lower != None and rpm_perc <= crit_lower:
                state = "CRIT"
            elif warn_lower != None and rpm_perc <= warn_lower:
                state = "WARN"
            
            return {
                "changed": False,
                "msg": msg_parts[0],
                "data": {"state": state, "metrics": {"speed_percent": rpm_perc}, "details": ""}
            }
    
    if not found:
        return {
            "changed": False,
            "msg": "fan not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }