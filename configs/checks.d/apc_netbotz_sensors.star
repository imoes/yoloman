def main(ctx, params):
    # Determine mode: discovery or check
    if params.get("_discover"):
        # Discover temperature sensors via SNMP
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.5528.100.4.1.1.1"
        
        # Fetch OID 4 (sensor labels) to discover items
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".4"
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            val = parts[1].strip()
            if val.startswith("STRING: "):
                label = val[8:].strip('"')
                # Extract item name from OID: base.1.OID -> item name is last component
                item_name = oid_val.rsplit(".", 1)[-1]
                if label:
                    items.append({
                        "item": item_name,
                        "params": {"levels": [30.0, 35.0], "levels_lower": [25.0, 20.0]},
                        "metrics": ["temperature"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: single item
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.5528.100.4.1.1.1"
    
    # Fetch the temperature reading (OID 7) for this item
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        base_oid + ".7." + item
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "unable to retrieve temperature for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output: .1.3.6.1.4.1.5528.100.4.1.1.1.7.<item> = STRING: "25.200000"
    line = res.stdout.strip()
    if line.startswith(base_oid + ".7." + item + " = STRING: "):
        value_str = line[len(base_oid + ".7." + item + " = STRING: "):].strip('"')
        if not value_str:
            return {
                "changed": False,
                "msg": "empty temperature value for item %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        if not value_str.replace(".", "").replace("-", "").isdigit():
            return {
                "changed": False,
                "msg": "invalid temperature value '%s' for item %s" % (value_str, item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
        raw_value = float(value_str)
        temperature = raw_value / 10.0  # Value is in tenths of degree
    else:
        return {
            "changed": False,
            "msg": "unexpected snmpget output for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Fetch label (OID 4) for this item
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        base_oid + ".4." + item
    ], mutates=False)
    
    label = ""
    if res.rc == 0 and res.stdout.strip():
        line = res.stdout.strip()
        if line.startswith(base_oid + ".4." + item + " = STRING: "):
            label = line[len(base_oid + ".4." + item + " = STRING: "):].strip('"')
    
    # Get thresholds
    levels = params.get("levels", [30.0, 35.0])
    levels_lower = params.get("levels_lower", [25.0, 20.0])
    
    warn_upper = float(levels[0]) if len(levels) > 0 else 30.0
    crit_upper = float(levels[1]) if len(levels) > 1 else 35.0
    warn_lower = float(levels_lower[0]) if len(levels_lower) > 0 else 25.0
    crit_lower = float(levels_lower[1]) if len(levels_lower) > 1 else 20.0
    
    # Determine state
    if temperature >= crit_upper:
        state = "CRIT"
    elif temperature >= warn_upper:
        state = "WARN"
    elif temperature <= crit_lower:
        state = "CRIT"
    elif temperature <= warn_lower:
        state = "WARN"
    else:
        state = "OK"
    
    # Format message
    msg_parts = []
    if label:
        msg_parts.append("[%s]" % label)
    msg_parts.append("Temperature: %f C" % temperature)
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"temperature": temperature},
            "details": ""
        }
    }
