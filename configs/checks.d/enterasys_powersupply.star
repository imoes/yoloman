def main(ctx, params):
    # Constants (must be defined at top level per Starlark rules)
    SUPPLY_TYPES = {
        "1": "ac-dc",
        "2": "dc-dc",
        "3": "notSupported",
        "4": "highOutput",
    }
    REDUNDANCY_TYPES = {
        "1": "redundant",
        "2": "notRedundant",
        "3": "notSupported",
    }
    DEFAULT_REDUNDANCY_OK_STATES = [1]
    
    # Get redundancy_ok_states from params, use default if absent
    redundancy_ok_states = params.get("redundancy_ok_states", DEFAULT_REDUNDANCY_OK_STATES)
    
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.52.4.3.1.2.1.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        # Parse snmpwalk output: each line is "<OID>.<end> = INTEGER: <value>"
        section = []
        lines = res.stdout.splitlines()
        i = 0
        while i < len(lines):
            # Look for the base OID entries: we need 4 consecutive values per item
            # We'll parse by extracting the end part and collecting 4 consecutive lines
            item_vals = []
            base_idx = i
            while i < len(lines) and len(item_vals) < 4:
                line = lines[i]
                # Check if this line is for our base OID (base OID + end)
                # Format: .1.3.6.1.4.1.52.4.3.1.2.1.1.<N> = INTEGER: <value>
                if line.find(".1.3.6.1.4.1.52.4.3.1.2.1.1.") == 0:
                    parts = line.split("=")
                    if len(parts) >= 2:
                        # Extract value
                        value_part = parts[1].strip()
                        val = value_part.split(":")
                        if len(val) >= 2:
                            item_vals.append(val[1].strip())
                i += 1
            
            # We need exactly 4 values: num, state, type, redundancy
            if len(item_vals) == 4:
                num, state, typ, redun = item_vals
                section.append([num, state, typ, redun])
            elif len(item_vals) > 0:
                # Skip incomplete entries
                pass
        
        # Now discover: yield item for each entry with state == "3" (installed and operating)
        discovery = []
        for entry in section:
            if len(entry) < 4:
                continue
            num, state, typ, redun = entry
            # According to source: state == "3" -> yield Service(item=num)
            # state values: 1=notInstalled, 2=notOperating, 3=installedAndOperating, 4=installedAndNotOperating
            if state == "3":
                # Get redundancy_ok_states from params (default [1])
                suggested_params = {"redundancy_ok_states": redundancy_ok_states}
                discovery.append({
                    "item": num,
                    "params": suggested_params,
                    "metrics": []  # no metrics, just status
                })
        
        return {"changed": False, "msg": "discovered %d PSUs" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode (non-discovery)
    item = params.get("item", "")
    
    # Get the data again via snmpwalk
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.52.4.3.1.2.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP output into section
    section = []
    lines = res.stdout.splitlines()
    i = 0
    while i < len(lines):
        item_vals = []
        while i < len(lines) and len(item_vals) < 4:
            line = lines[i]
            if line.find(".1.3.6.1.4.1.52.4.3.1.2.1.1.") == 0:
                parts = line.split("=")
                if len(parts) >= 2:
                    value_part = parts[1].strip()
                    val = value_part.split(":")
                    if len(val) >= 2:
                        item_vals.append(val[1].strip())
            i += 1
        
        if len(item_vals) == 4:
            num, state, typ, redun = item_vals
            section.append([num, state, typ, redun])
        elif len(item_vals) > 0:
            pass
    
    # Find matching item
    found = False
    for entry in section:
        if len(entry) < 4:
            continue
        num, state, typ, redun = entry
        if num != item:
            continue
        
        found = True
        
        # State handling per source:
        # state "4" -> CRIT: "Status: installed and not operating"
        if state == "4":
            return {
                "changed": False,
                "msg": "Status: installed and not operating",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}
            }
        
        # Get redundancy type mapping
        redun_mapped = REDUNDANCY_TYPES.get(redun, "unknown[%s]" % redun)
        
        # Check if redundancy state is in allowed states
        # Note: redun is string, so convert to int for comparison
        # Guard before conversion: only convert if redun consists of digits
        redun_int = int(redun) if redun.isdigit() else None
        
        # Check redundancy_ok_states (list of ints)
        if redun != None and redun_int != None and redun_int in redundancy_ok_states:
            supply_type = SUPPLY_TYPES.get(typ, "unknown[%s]" % typ)
            return {
                "changed": False,
                "msg": "Status: working and %s (%s)" % (redun_mapped, supply_type),
                "data": {"state": "OK", "metrics": {}, "details": ""}
            }
        
        # Fallback: WARN with redundancy status
        return {
            "changed": False,
            "msg": "Status: %s" % redun_mapped,
            "data": {"state": "WARN", "metrics": {}, "details": ""}
        }
    
    if not found:
        return {"changed": False, "msg": "PSU item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    return {"changed": False, "msg": "unexpected end",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
