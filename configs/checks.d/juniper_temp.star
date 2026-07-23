def main(ctx, params):
    # Juniper temperature check via SNMP
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        # Fetch both OID trees: description tree (.5.7) and temperature reading tree (.7.7)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.2636.3.1.13.1.5.7",  # descriptions
            ".1.3.6.1.4.1.2636.3.1.13.1.7.7"          # temperatures
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                    "data": {"discovery": []}}
        
        # Parse SNMP output: lines are "OID = TYPE: value"
        descriptions = {}
        temperatures = {}
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            # Determine tree: .5.7 or .7.7
            if oid_part.strip().startswith(".1.3.6.1.4.1.2636.3.1.13.1.5.7."):
                # Description tree
                suffix = oid_part.strip().rsplit(".", 1)[1]
                descriptions[suffix] = value_part.strip()
            elif oid_part.strip().startswith(".1.3.6.1.4.1.2636.3.1.13.1.7.7."):
                # Temperature tree
                suffix = oid_part.strip().rsplit(".", 1)[1]
                val_str = value_part.split(": ", 1)[1].strip() if ": " in value_part else ""
                temperature = float(val_str) if val_str and val_str.replace(".","").replace("-","").isdigit() else -1.0
                temperatures[suffix] = temperature
        
        # Match descriptions to temperatures by suffix and filter >0
        items = []
        for suffix, temp in temperatures.items():
            if temp > 0:
                desc = descriptions.get(suffix, suffix)
                # Clean description: remove colons, "/*", "@ "
                desc = desc.replace(":", "").replace("/*", "").replace("@ ", "").strip()
                if desc:
                    items.append({
                        "item": desc,
                        "params": {"levels": (55.0, 60.0)},
                        "metrics": ["juniper_temp_" + desc]
                    })
        
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: single item
    item = params.get("item", "")
    warn, crit = params.get("levels", (55.0, 60.0))
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.2636.3.1.13.1.5.7",  # descriptions
        ".1.3.6.1.4.1.2636.3.1.13.1.7.7"          # temperatures
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Rebuild mapping
    descriptions = {}
    temperatures = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        if oid_part.strip().startswith(".1.3.6.1.4.1.2636.3.1.13.1.5.7."):
            suffix = oid_part.strip().rsplit(".", 1)[1]
            descriptions[suffix] = value_part.strip()
        elif oid_part.strip().startswith(".1.3.6.1.4.1.2636.3.1.13.1.7.7."):
            suffix = oid_part.strip().rsplit(".", 1)[1]
            val_str = value_part.split(": ", 1)[1].strip() if ": " in value_part else ""
            temp_val = float(val_str) if val_str and val_str.replace(".","").replace("-","").isdigit() else -1.0
            temperatures[suffix] = temp_val
    
    # Find matching temperature by description
    temperature = None
    for suffix, desc in descriptions.items():
        clean_desc = desc.replace(":", "").replace("/*", "").replace("@ ", "").strip()
        if clean_desc == item:
            if suffix in temperatures and temperatures[suffix] > 0:
                temperature = temperatures[suffix]
            break
    
    if temperature == None:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Determine state
    state = "OK"
    if temperature >= crit:
        state = "CRIT"
    elif temperature >= warn:
        state = "WARN"
    
    msg = "%s: %f °C" % (item, temperature)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"juniper_temp_" + item: temperature},
            "details": ""
        }
    }