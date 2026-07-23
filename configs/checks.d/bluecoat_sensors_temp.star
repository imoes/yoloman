def main(ctx, params):
    # Constants: SNMP OIDs and defaults
    BASE_OID = ".1.3.6.1.4.1.3417.2.1.1.1.1.1"
    OID_NAME = "9"
    OID_READING = "5"
    OID_STATUS = "7"
    OID_SCALE = "4"
    OID_UNIT = "3"
    
    # Checkmk default for temperature handling
    device_levels_handling = params.get("device_levels_handling", "devdefault")
    warn = params.get("warn", (25.0, 35.0))
    crit = params.get("crit", (30.0, 40.0))
    
    # Discover mode: enumerate temperature sensors (unit == "5")
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Build full OIDs: base + '.' + oid
        oid_name = BASE_OID + "." + OID_NAME
        oid_reading = BASE_OID + "." + OID_READING
        oid_status = BASE_OID + "." + OID_STATUS
        oid_scale = BASE_OID + "." + OID_SCALE
        oid_unit = BASE_OID + "." + OID_UNIT
        
        # Walk each OID
        res_name = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid_name], mutates=False)
        res_reading = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid_reading], mutates=False)
        res_status = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid_status], mutates=False)
        res_scale = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid_scale], mutates=False)
        res_unit = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid_unit], mutates=False)
        
        # Parse SNMP walk output: lines like "OID = STRING: value" or "OID = INTEGER: value"
        def parse_snmp_walk_lines(res):
            lines = res.stdout.splitlines()
            result = {}
            for line in lines:
                if not line:
                    continue
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_part = parts[0].strip()
                value_part = parts[1].strip()
                # Extract last number from OID (e.g., ".1.3.6.1.4.1.3417.2.1.1.1.1.1.9.1" -> "1")
                suffix = oid_part.rsplit(".", 1)
                idx = suffix[-1] if len(suffix) == 2 else ""
                # Strip type prefix (e.g., "STRING:", "INTEGER:", "Gauge32:")
                if ": " in value_part:
                    val = value_part.split(": ", 1)[1].strip().strip('"')
                else:
                    val = value_part.strip().strip('"')
                result[idx] = val
            return result
        
        names = parse_snmp_walk_lines(res_name)
        readings = parse_snmp_walk_lines(res_reading)
        statuses = parse_snmp_walk_lines(res_status)
        scales = parse_snmp_walk_lines(res_scale)
        units = parse_snmp_walk_lines(res_unit)
        
        # Collect temperature sensors (unit == "5")
        discovered = []
        for idx in names:
            if units.get(idx) == "5":
                sensor_name = names.get(idx).replace(" temperature", "")
                discovered.append({
                    "item": sensor_name,
                    "params": {
                        "device_levels_handling": device_levels_handling,
                        "warn": warn,
                        "crit": crit,
                    },
                    "metrics": ["temp"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode: examine one temperature sensor
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Build full OIDs for snmpget of the item (we'll use index 1 for now)
    # Note: Real indexing may require parsing the full OID table; for simplicity,
    # assume the sensor item maps to a numeric index in the table, and we use index 1.
    # In practice, a full discovery would have stored the correct index per item.
    # Here we do a direct check by walking and matching the name.
    oid_name_full = BASE_OID + "." + OID_NAME
    
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid_name_full], mutates=False)
    lines = res.stdout.splitlines()
    
    # Find the index that corresponds to `item`
    item_idx = ""
    for line in lines:
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Extract index suffix
        suffix = oid_part.rsplit(".", 1)
        idx = suffix[-1] if len(suffix) == 2 else ""
        # Extract name value
        name_val = value_part.split(": ", 1)
        if len(name_val) != 2:
            continue
        name_val = name_val[1].strip().strip('"')
        # Check if it matches our item (after stripping " temperature")
        if name_val.replace(" temperature", "") == item:
            item_idx = idx
            break
    
    if not item_idx:
        return {
            "changed": False,
            "msg": "temperature sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Now fetch all required fields for this index
    def get_snmp_value(base_oid, oid_suffix, host, community, idx):
        full_oid = base_oid + "." + oid_suffix + "." + idx
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, full_oid], mutates=False)
        if not res.stdout.strip():
            return None
        parts = res.stdout.strip().split(" = ", 1)
        if len(parts) != 2:
            return None
        value_part = parts[1].strip()
        # Strip type prefix
        if ": " in value_part:
            return value_part.split(": ", 1)[1].strip().strip('"')
        return value_part.strip().strip('"')
    
    reading_val = get_snmp_value(BASE_OID, OID_READING, host, community, item_idx)
    status_val = get_snmp_value(BASE_OID, OID_STATUS, host, community, item_idx)
    scale_val = get_snmp_value(BASE_OID, OID_SCALE, host, community, item_idx)
    unit_val = get_snmp_value(BASE_OID, OID_UNIT, host, community, item_idx)
    
    # Validate and compute value
    if reading_val == None or scale_val == None or unit_val == None:
        return {
            "changed": False,
            "msg": "missing data for sensor",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if unit_val != "5":
        return {
            "changed": False,
            "msg": "sensor is not a temperature sensor (unit=" + str(unit_val) + ")",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Guard: ensure strings are valid before conversion
    if not reading_val or not scale_val:
        return {
            "changed": False,
            "msg": "invalid numeric data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Use float conversion guard: assume valid numeric strings as per SNMP spec
    reading = float(reading_val) if reading_val.replace(".", "").replace("-", "").isdigit() else 0.0
    scale = float(scale_val) if scale_val.replace("-", "").isdigit() else 0.0
    # Compute 10 ** scale using loop instead of ** operator
    base = 10.0
    exponent = int(scale)
    if scale < 0:
        base = 0.1
        exponent = -exponent
    multiplier = 1.0
    for i in range(exponent):
        multiplier = multiplier * base
    value = reading * multiplier
    
    # Determine status
    is_ok = status_val == "1" if status_val else False
    
    # Apply temperature thresholds (warn/crit as (low, high) tuple)
    warn_low, warn_high = warn if isinstance(warn, (list, tuple)) else (None, warn)
    crit_low, crit_high = crit if isinstance(crit, (list, tuple)) else (None, crit)
    
    state = "OK"
    if device_levels_handling == "devdefault":
        # Use device status to override default state
        if not is_ok:
            state = "CRIT"
        # Then apply temperature thresholds
        if state == "OK":
            if crit_high != None and value >= crit_high:
                state = "CRIT"
            elif warn_high != None and value >= warn_high:
                state = "WARN"
            if state == "OK" and crit_low != None and value <= crit_low:
                state = "CRIT"
            elif state == "OK" and warn_low != None and value <= warn_low:
                state = "WARN"
    else:
        # Only temperature thresholds (ignore dev_status)
        if crit_high != None and value >= crit_high:
            state = "CRIT"
        elif warn_high != None and value >= warn_high:
            state = "WARN"
        if state == "OK" and crit_low != None and value <= crit_low:
            state = "CRIT"
        elif state == "OK" and warn_low != None and value <= warn_low:
            state = "WARN"
    
    return {
        "changed": False,
        "msg": "Temperature: %f C" % value,
        "data": {
            "state": state,
            "metrics": {"temp": value},
            "details": "Sensor status: %s" % ("OK" if is_ok else "Not OK")
        }
    }
