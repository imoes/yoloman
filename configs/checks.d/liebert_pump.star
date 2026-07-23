def main(ctx, params):
    # Discover mode: enumerate pump items
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        names_oid = base_oid + ".10.1.2.1.5298"
        values_oid = base_oid + ".20.1.2.1.5298"
        units_oid = base_oid + ".30.1.2.1.5298"
        
        res_names = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, names_oid], mutates=False)
        res_values = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, values_oid], mutates=False)
        res_units = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, units_oid], mutates=False)
        
        # Parse snmpwalk output: OID -> value string
        def parse_snmpwalk_output(output):
            result = {}
            lines = output.splitlines()
            for i in range(len(lines)):
                line = lines[i]
                stripped = line.strip()
                if stripped == "":
                    continue
                idx = stripped.find(" = ", 0)
                if idx == -1:
                    continue
                oid = stripped[:idx].strip()
                value_part = stripped[idx + 3:].strip()
                colon_idx = value_part.find(": ", 0)
                if colon_idx != -1:
                    value_part = value_part[colon_idx + 2:].strip()
                    if len(value_part) >= 2 and value_part[0] == '"' and value_part[len(value_part)-1] == '"':
                        value_part = value_part[1:len(value_part)-1]
                result[oid] = value_part
            return result
        
        names = parse_snmpwalk_output(res_names.stdout)
        values = parse_snmpwalk_output(res_values.stdout)
        units = parse_snmpwalk_output(res_units.stdout)
        
        section = {}
        threshold_section = {}
        
        for key in names:
            name = names.get(key)
            if name == "" or name.find("Threshold") != -1:
                if name != "" and name.find("Threshold") != -1:
                    threshold_section[name.replace(" Threshold", "")] = key
                continue
            
            value_str = values.get(key)
            unit_str = units.get(key)
            
            # Guard instead of try/except: only process if value_str is numeric
            if value_str != None and value_str.isdigit():
                value = float(value_str)
                unit = unit_str if unit_str != None else ""
                section[name] = (value, unit)
        
        discovery = []
        for item_name in section:
            if item_name.lower().find("threshold") == -1:
                discovery.append({
                    "item": item_name,
                    "params": {"levels": (90.0, 95.0)},
                    "metrics": ["pump_hours"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d pump items" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode: verify one item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    base_oid = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    names_oid = base_oid + ".10.1.2.1.5298"
    values_oid = base_oid + ".20.1.2.1.5298"
    units_oid = base_oid + ".30.1.2.1.5298"
    
    res_names = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, names_oid], mutates=False)
    res_values = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, values_oid], mutates=False)
    res_units = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, units_oid], mutates=False)
    
    def parse_snmpwalk_output(output):
        result = {}
        lines = output.splitlines()
        for i in range(len(lines)):
            line = lines[i]
            stripped = line.strip()
            if stripped == "":
                continue
            idx = stripped.find(" = ", 0)
            if idx == -1:
                continue
            oid = stripped[:idx].strip()
            value_part = stripped[idx + 3:].strip()
            colon_idx = value_part.find(": ", 0)
            if colon_idx != -1:
                value_part = value_part[colon_idx + 2:].strip()
                if len(value_part) >= 2 and value_part[0] == '"' and value_part[len(value_part)-1] == '"':
                    value_part = value_part[1:len(value_part)-1]
            result[oid] = value_part
        return result
    
    names = parse_snmpwalk_output(res_names.stdout)
    values = parse_snmpwalk_output(res_values.stdout)
    units = parse_snmpwalk_output(res_units.stdout)
    
    section = {}
    threshold_section = {}
    
    for key in names:
        name = names.get(key)
        if name == "" or name.find("Threshold") != -1:
            if name != "" and name.find("Threshold") != -1:
                threshold_section[name.replace(" Threshold", "")] = key
            continue
        value_str = values.get(key)
        unit_str = units.get(key)
        if value_str != None and value_str.isdigit():
            value = float(value_str)
            unit = unit_str if unit_str != None else ""
            section[name] = (value, unit)
    
    # Guard: item must exist
    if not section.get(item):
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value, unit = section.get(item)
    
    # Get threshold
    threshold_oid = threshold_section.get(item)
    threshold = None
    if threshold_oid != None:
        threshold_value_str = values.get(threshold_oid)
        if threshold_value_str != None and threshold_value_str.isdigit():
            threshold = float(threshold_value_str)
    
    # Apply levels
    warn = None
    crit = None
    levels_param = params.get("levels")
    if levels_param != None:
        if type(levels_param) == "list" and len(levels_param) == 2:
            warn = levels_param[0]
            crit = levels_param[1]
        else:
            warn = levels_param
            crit = levels_param
    
    # Check levels (upper limits: warn/crit are upper thresholds)
    state = "OK"
    
    if threshold != None:
        warn = threshold
        crit = threshold
    
    if warn != None and crit != None:
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    elif warn != None:
        if value >= warn:
            state = "WARN"
    
    # Format message
    msg = "%s %f %s" % (item, value, unit)
    if state == "WARN":
        msg += " (warn at %f)" % warn
    elif state == "CRIT":
        msg += " (crit at %f)" % crit
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"pump_hours": value},
            "details": ""
        }
    }