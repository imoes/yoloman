def main(ctx, params):
    # Checkmk check: liebert_fans_condenser
    # Read-only Starlark translation: SNMP-based fan monitoring
    # No mutates=True, no file writes, always changed=False

    # Parameters (defaults from Checkmk)
    warn = params.get("levels", (80.0, 90.0))
    warn_upper = warn[0]
    crit_upper = warn[1]
    warn_lower = params.get("levels_lower", None)
    crit_lower = None  # not used in default; keep consistent with original
    if warn_lower != None:
        warn_lower = warn_lower[0]
        crit_lower = warn_lower[0] if len(warn_lower) > 1 else None

    # Discovery mode: enumerate fan items
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        
        # Fetch all three OID trees (base.10.1.2.1.5276, .20.1.2.1.5276, .30.1.2.1.5276)
        # Use snmpwalk on the base OID to collect all rows
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid
        ], mutates=False)
        
        # Parse snmpwalk output lines: "<OID> = STRING: <name>|<value>|<unit>"
        # But the original code expects 3-oid rows: name, value, unit (from three separate OIDs)
        # The section uses parse_liebert_float, which expects: name, value, unit per triple
        # Since snmpwalk returns all OIDs as one flat list, we must reconstruct the triples
        
        # Build a map from index to (name, value, unit)
        # OID structure:
        #   base.10.1.2.1.5276.<index> -> name  (STRING)
        #   base.20.1.2.1.5276.<index> -> value (STRING float)
        #   base.30.1.2.1.5276.<index> -> unit  (STRING)
        index_to_name = {}
        index_to_value = {}
        index_to_unit = {}
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Split on " = " to separate OID and value
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_str, value_str = parts
            # Extract suffix
            suffix = oid_str.rsplit(".", 1)[-1]
            base_suffix = oid_str[len(base_oid)+1:] if oid_str.startswith(base_oid + ".") else ""
            if not base_suffix:
                continue
            
            # Parse base_suffix like "10.1.2.1.5276.123"
            # The first component is the table index offset (10,20,30)
            components = base_suffix.split(".")
            if len(components) < 2:
                continue
            table_id = components[0]
            if table_id == "10":
                # name
                index_to_name[suffix] = value_str.strip('"')
            elif table_id == "20":
                # value
                index_to_value[suffix] = value_str.strip('"')
            elif table_id == "30":
                # unit
                index_to_unit[suffix] = value_str.strip('"')
        
        # Combine into items: (index, name, value, unit)
        items = []
        for idx in sorted(index_to_name.keys()):
            if idx in index_to_name and idx in index_to_value and idx in index_to_unit:
                name = index_to_name[idx]
                value_str = index_to_value[idx]
                unit_str = index_to_unit[idx]
                # Guard instead of try/except: check value string validity before converting
                v_str = value_str.replace(".", "", 1)
                v_valid = v_str.isdigit() or (v_str.startswith("-") and v_str[1:].isdigit())
                if v_valid:
                    value = float(value_str)
                    items.append({
                        "item": name,
                        "params": {"levels": [warn_upper, crit_upper]},
                        "metrics": ["fan_perc"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: examine one item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    
    # Fetch data for this item via snmpget for each OID column
    # OID suffix for item is the numeric index in the table; but we don't know it.
    # Instead, walk all rows and find the one matching 'item'
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base_oid
    ], mutates=False)
    
    index_to_name = {}
    index_to_value = {}
    index_to_unit = {}
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_str, value_str = parts
        suffix = oid_str.rsplit(".", 1)[-1]
        base_suffix = oid_str[len(base_oid)+1:] if oid_str.startswith(base_oid + ".") else ""
        if not base_suffix:
            continue
        
        components = base_suffix.split(".")
        if len(components) < 2:
            continue
        table_id = components[0]
        if table_id == "10":
            index_to_name[suffix] = value_str.strip('"')
        elif table_id == "20":
            index_to_value[suffix] = value_str.strip('"')
        elif table_id == "30":
            index_to_unit[suffix] = value_str.strip('"')
    
    # Find matching item
    found = None
    for idx in index_to_name.keys():
        if index_to_name[idx] == item:
            value_str = index_to_value.get(idx)
            unit_str = index_to_unit.get(idx)
            if value_str != None and unit_str != None:
                v_str = value_str.replace(".", "", 1)
                v_valid = v_str.isdigit() or (v_str.startswith("-") and v_str[1:].isdigit())
                if v_valid:
                    value = float(value_str)
                    unit = unit_str
                    found = (value, unit)
            break
    
    if found == None:
        return {
            "changed": False,
            "msg": "fan item '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value, unit = found
    
    # Determine state
    state = "OK"
    details = "Fan speed: %f %s" % (value, unit)
    metric_value = value
    
    # Upper levels
    if crit_upper != None and value >= crit_upper:
        state = "CRIT"
        details += " (critical above %f)" % crit_upper
    elif warn_upper != None and value >= warn_upper:
        state = "WARN"
        details += " (warning above %f)" % warn_upper
    
    # Lower levels (if configured)
    if state == "OK" and crit_lower != None and value <= crit_lower:
        state = "CRIT"
        details += " (critical below %f)" % crit_lower
    elif state == "OK" and warn_lower != None and value <= warn_lower:
        state = "WARN"
        details += " (warning below %f)" % warn_lower
    
    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": {"fan_perc": metric_value},
            "details": ""
        }
    }