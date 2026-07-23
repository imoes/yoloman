def main(ctx, params):
    # SNMP base OID and units for cmctc_ports
    base_oid = ".1.3.6.1.4.1.2606.4.2"
    units = ["3", "4", "5", "6"]
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Collect all lines from all units
    all_lines = []
    for unit in units:
        base = base_oid + "." + unit
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base], mutates=False)
        all_lines.extend(res.stdout.splitlines())
    
    # Parse SNMP output: map OID suffix to values
    data_by_unit = {}
    
    # Parse all lines: extract base and suffix
    for line in all_lines:
        if line == None or " = " not in line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        
        # Extract type and value: e.g., "INTEGER: 2" or "STRING: CMC-TC-IOU"
        typ = ""
        val = ""
        if ":" in value_part:
            p = value_part.split(":", 1)
            typ = p[0].strip()
            val = p[1].strip()
            # Remove quotes from STRING values
            if val.startswith("\"") and val.endswith("\"") and len(val) >= 2:
                val = val[1:len(val)-1]
        
        # Check if this OID belongs to our range
        if not oid_part.startswith(base_oid + "."):
            continue
        suffix = oid_part[len(base_oid) + 1:]
        # We expect suffix like "3.1.0", "3.2.0", etc.
        if "." not in suffix:
            continue
        # Split suffix into unit_suffix, field_idx, index
        s = suffix.split(".")
        if len(s) != 3:
            continue
        unit_suffix = s[0]
        field_idx_str = s[1]
        
        if unit_suffix not in units:
            continue
        if not field_idx_str.isdigit():
            continue
        unit_num = int(unit_suffix)
        field_idx = int(field_idx_str)
        
        # Store by unit
        if unit_num not in data_by_unit:
            data_by_unit[unit_num] = [None, None, None, None]
        if field_idx >= 1 and field_idx <= 4:
            data_by_unit[unit_num][field_idx - 1] = val
    
    # Type and status maps (same as Checkmk)
    type_map = {
        "1": "not available",
        "2": "IO",
        "3": "Access",
        "4": "Climate",
        "5": "FCS",
        "6": "RTT",
        "7": "RTC",
        "8": "PSM",
        "9": "PSM8",
        "10": "PSM metered",
        "11": "IO wireless",
        "12": "PSM6 Schuko",
        "13": "PSM6C19",
        "14": "Fuel Cell",
        "15": "DRC",
        "16": "TE cooler",
        "17": "PSM32 metered",
        "18": "PSM8x8",
        "19": "PSM6x6 Schuko",
        "20": "PSM6x6C19",
    }

    # Status code map: raw SNMP status code -> text
    status_code_map = {
        "1": "ok",
        "2": "error",
        "3": "configuration changed",
        "4": "quit from sensor unit",
        "5": "timeout",
        "6": "unit detected",
        "7": "not available",
        "8": "supply voltage low",
    }

    # Status text -> state
    status_to_state = {
        "ok": "OK",
        "configuration changed": "WARN",
        "unit detected": "WARN",
        "error": "CRIT",
        "quit from sensor unit": "CRIT",
        "timeout": "CRIT",
        "not available": "CRIT",
        "supply voltage low": "CRIT",
    }

    # Discovery mode
    if params.get("_discover"):
        out = []
        for unit_num in sorted(data_by_unit.keys()):
            port_data = data_by_unit[unit_num]
            description = port_data[1]
            device_status = port_data[3]
            
            # Skip if incomplete or not available
            if description == None or description == "":
                continue
            # Check if status indicates "not available"
            if device_status == "7":
                continue
            
            # Build item name: "%d %s" % (number, description)
            item_name = str(unit_num) + " " + description
            
            # Metrics: none for this check
            out.append({"item": item_name, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d ports" % len(out),
                "data": {"discovery": out}}

    # Check mode: one item
    item = params.get("item", "")
    # Parse item name to get unit number (first token is the number)
    parts = item.split(" ", 1)
    if len(parts) < 1:
        return {"changed": False, "msg": "invalid item name: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    unit_num_str = parts[0]
    if not unit_num_str.isdigit():
        return {"changed": False, "msg": "invalid unit number in item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    unit_num = int(unit_num_str)

    # Find data for this unit
    port_data = data_by_unit.get(unit_num)
    if port_data == None or len(port_data) < 4:
        return {"changed": False, "msg": "no data for port: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build port entry
    device_type = port_data[0]
    description = port_data[1]
    serial_number = port_data[2]
    device_status = port_data[3]

    # Translate type
    port_type = type_map.get(device_type if device_type != None else "", "")
    
    # Map raw status code to text
    status_text_raw = status_code_map.get(device_status if device_status != None else "", "")
    
    # Map textual status to state
    state_code = status_to_state.get(status_text_raw, "UNKNOWN")
    
    # Build info text
    status_text = status_text_raw if status_text_raw != "" else (device_status if device_status != None else "")
    type_display = port_type if port_type != "" else (device_type if device_type != None else "")
    serial_display = serial_number if serial_number != None else ""
    
    infotext = "Status: %s, Device type: %s, Serial number: %s" % (status_text, type_display, serial_display)
    
    return {"changed": False, "msg": infotext,
            "data": {"state": state_code, "metrics": {}, "details": ""}}
