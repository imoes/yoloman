# Constants mapped from the original Checkmk plugin
_MAP_SENSOR_TYPE = {
    "1": "temp",
    "2": "humidity",
    "3": "dewpoint",
}

_MAP_UNITS = {
    "0": "c",
    "1": "f",
    "2": "k",
    "3": "percent",
}

_MAP_STATES = {
    "0": (0, "OK"),
    "1": (3, "not available"),
    "2": (1, "over-flow"),
    "3": (1, "under-flow"),
    "4": (2, "error"),
}

# SNMP base OID
_BASE_OID = ".1.3.6.1.4.1.18248.20.1.2.1.1"

def _discover_sensors(ctx, sensor_type):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", ctx.facts().get("snmp_community", "public"),
        "-On", ctx.facts().get("hostname", "localhost"),
        "%s.1" % _BASE_OID
    ], mutates=False)
    
    sensors = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        oid_end = parts[0].rsplit(".", 1)[-1]
        value_part = parts[1].strip()
        # Extract state (first number after "INTEGER: " or similar type)
        # Standard snmpwalk output: OID = TYPE: value
        if ": " in value_part:
            value = value_part.split(": ", 1)[1].strip()
        else:
            value = value_part
        # Parse state, reading, unit from the four OIDs
        # We need to fetch all four OIDs per sensor to reconstruct the record
        # Instead, we'll walk each OID separately per sensor index
        
        # Re-structure: we need to walk all four OIDs together
        pass  # We'll rewrite to a combined walk
    
    # Better approach: walk base OID and parse index-specific data
    # Re-parse using full walk on base OID and extract data per OID end
    # Walk base OID
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", ctx.facts().get("snmp_community", "public"),
        "-On", ctx.facts().get("hostname", "localhost"), _BASE_OID
    ], mutates=False)
    
    parsed = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0]
        value_part = parts[1].strip()
        if ": " in value_part:
            value = value_part.split(": ", 1)[1].strip()
        else:
            value = value_part
        
        # Extract index (the last number after base OID)
        if full_oid.startswith(_BASE_OID + "."):
            suffix = full_oid[len(_BASE_OID) + 1:]
            if "." in suffix:
                # We need to handle multi-level OID ends; extract last component
                index = suffix.rsplit(".", 1)[-1]
            else:
                index = suffix
            
            # Determine OID subfield: 1=state, 2=reading, 3=unit
            field_part = suffix.rsplit(".", 1)[0].rsplit(".", 1)[-1] if "." in suffix else "1"
            
            # Get index from OID: .base.1.1.2.1 etc means index 1, field 2
            # Parse: base + .field + .index
            # Our OID: base.1 = state, base.2 = reading, base.3 = unit
            # Full OID format: .1.3.6.1.4.1.18248.20.1.2.1.1.[field].[index]
            parts_oid = suffix.split(".")
            if len(parts_oid) >= 2:
                field = parts_oid[0]
                idx = parts_oid[-1]
                
                if idx not in parsed:
                    parsed[idx] = {}
                
                # Store by field
                if field in ["1", "2", "3"]:
                    parsed[idx][field] = value
    
    # Now parse sensor data
    items = []
    for idx, fields in parsed.items():
        if "1" not in fields or "2" not in fields or "3" not in fields:
            continue
        state_str = fields["1"]
        if state_str == "3":
            continue  # Skip "not available" per original logic
        
        reading_str = fields["2"]
        unit_str = fields["3"]
        
        sensor_ty = _MAP_SENSOR_TYPE.get(state_str, "temp")  # This is wrong, fix below
        # Actually: sensor type is determined by index? No: OID .1 is state, .2 reading, .3 unit
        # Original uses OID end to determine type: field "1" = state, but state determines type?
        # Wait: re-read original: oidend is the index; field 1=state, 2=reading, 3=unit
        # But sensor type comes from the OID end? No: original code:
        #   sensor_ty = _MAP_SENSOR_TYPE[oidend]  # This is wrong in my reading
        
        # Correction: original has oidend as the sensor index, but uses it to determine type?
        # Let me check original again:
        #   for oidend, state, reading_str, unit in string_table:
        #       if state != "3":
        #           sensor_ty = _MAP_SENSOR_TYPE[oidend]
        #
        # But oidend is "1", "2", "3" (the index), not the sensor type.
        # Wait: original SNMP tree:
        #   base=".1.3.6.1.4.1.18248.20.1.2.1.1",
        #   oids=[OIDEnd(), "1", "2", "3"],
        # So OIDEnd returns the index, and state is from OID .1, reading from .2, unit from .3.
        # But the original parses sensor type as _MAP_SENSOR_TYPE[oidend], which is wrong.
        # Actually: re-check the original example output:
        # .1.3.6.1.4.1.18248.20.1.2.1.1.1.1 0  <-- state of sensor 1
        # .1.3.6.1.4.1.18248.20.1.2.1.1.1.2 249 <-- reading of sensor 1
        # .1.3.6.1.4.1.18248.20.1.2.1.1.1.3 0   <-- unit of sensor 1
        # .1.3.6.1.4.1.18248.20.1.2.1.1.2.1 0   <-- state of sensor 2
        # .1.3.6.1.4.1.18248.20.1.2.1.1.2.2 317 <-- reading of sensor 2
        # .1.3.6.1.4.1.18248.20.1.2.1.1.2.3 3   <-- unit of sensor 2
        # .1.3.6.1.4.1.18248.20.1.2.1.1.3.1 0   <-- state of sensor 3
        # .1.3.6.1.4.1.18248.20.1.2.1.1.3.2 69  <-- reading of sensor 3
        # .1.3.6.1.4.1.18248.20.1.2.1.1.3.3 0   <-- unit of sensor 3
        #
        # So OID end is 1,2,3 (sensor index), and the sensor type is stored in the OID itself?
        # Actually no: in the original, sensor type is determined by OID end: "1"=temp, "2"=humidity, "3"=dewpoint
        # That means: sensor 1 is temp, sensor 2 is humidity, sensor 3 is dewpoint.
        # So the original uses oidend as a sensor type key. That matches _MAP_SENSOR_TYPE.
        # So for index 1, type=temp; index 2, type=humidity; index 3, type=dewpoint.
        # Therefore: sensor_ty = _MAP_SENSOR_TYPE.get(oidend, "temp")
        
        # In our parsed structure: idx is the OID end (1,2,3)
        sensor_ty = _MAP_SENSOR_TYPE.get(idx, "temp")
        if sensor_ty != sensor_type:
            continue
        
        state_str = fields["1"]
        state_info = _MAP_STATES.get(state_str, (2, "error"))
        reading = float(fields["2"]) / 10 if fields["2"].lstrip('-').isdigit() else 0.0
        unit = _MAP_UNITS.get(fields["3"], "c")
        
        # Store per item
        item_name = "Sensor " + idx
        parsed.setdefault(sensor_ty, {})
        parsed[sensor_ty].setdefault(item_name, (state_info, reading, unit))
    
    return list(parsed.get(sensor_type, {}).keys()) if sensor_type in parsed else []


def _check_temperature(ctx, params, item, sensor_type):
    # Walk and parse as in discover
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", ctx.facts().get("snmp_community", "public"),
        "-On", ctx.facts().get("hostname", "localhost"), _BASE_OID
    ], mutates=False)
    
    parsed = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        full_oid = parts[0]
        value_part = parts[1].strip()
        if ": " in value_part:
            value = value_part.split(": ", 1)[1].strip()
        else:
            value = value_part
        
        if full_oid.startswith(_BASE_OID + "."):
            suffix = full_oid[len(_BASE_OID) + 1:]
            parts_oid = suffix.split(".")
            if len(parts_oid) >= 2:
                field = parts_oid[0]
                idx = parts_oid[-1]
                
                if idx not in parsed:
                    parsed[idx] = {}
                
                if field in ["1", "2", "3"]:
                    parsed[idx][field] = value
    
    # Find the specific item
    sensor_ty = _MAP_SENSOR_TYPE.get(item.lstrip("Sensor "), "temp")
    if sensor_ty != sensor_type:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Check if item exists in parsed (by "Sensor " + idx)
    item_idx = item.lstrip("Sensor ")
    fields = parsed.get(item_idx, {})
    if "1" not in fields or "2" not in fields or "3" not in fields:
        return {
            "changed": False,
            "msg": "sensor data missing for " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state_str = fields["1"]
    if state_str == "3":
        return {
            "changed": False,
            "msg": "sensor not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    state_info = _MAP_STATES.get(state_str, (2, "error"))
    reading_str = fields["2"]
    reading = float(reading_str) / 10 if reading_str.lstrip('-').isdigit() else 0.0
    unit = _MAP_UNITS.get(fields["3"], "c")
    state_code = state_info[0]
    
    # Threshold handling for temperature
    # Checkmk default: no levels
    # Use standard temp params
    warn = params.get("levels", (None, None))
    warn_upper = warn[0] if warn and len(warn) >= 1 and warn[0] != None else None
    crit_upper = warn[1] if warn and len(warn) >= 2 and warn[1] != None else None
    warn_lower = params.get("levels_lower", (None, None))[0] if params.get("levels_lower") else None
    crit_lower = params.get("levels_lower", (None, None))[1] if params.get("levels_lower") else None
    
    # Determine state based on temperature levels
    state = state_code
    details_parts = []
    
    # Convert unit to Checkmk unit names for comparison
    # c=°C, f=°F, k=K; standard temp check expects Celsius
    # Convert reading to Celsius for comparison if needed
    temp_c = reading
    if unit == "f":
        temp_c = (reading - 32) * 5.0 / 9.0
    elif unit == "k":
        temp_c = reading - 273.15
    
    # Apply levels
    if crit_upper != None and temp_c >= crit_upper:
        state = max(state, 2)
    elif warn_upper != None and temp_c >= warn_upper:
        state = max(state, 1)
    
    if crit_lower != None and temp_c <= crit_lower:
        state = max(state, 2)
    elif warn_lower != None and temp_c <= warn_lower:
        state = max(state, 1)
    
    state_name = ("OK", "WARNING", "CRITICAL", "UNKNOWN")[min(state, 3)]
    
    # Build summary
    unit_symbol = {"c": "°C", "f": "°F", "k": "K"}.get(unit, unit)
    details_parts.append("Status: " + state_info[1])
    details_parts.append("Temperature: %f %s" % (reading, unit_symbol))
    
    # Metrics: name -> number
    metrics = {"temperature": temp_c}
    if unit == "f":
        metrics["temperature_celsius"] = temp_c
    
    return {
        "changed": False,
        "msg": "%s: %s" % (item, state_name),
        "data": {
            "state": state_name,
            "metrics": metrics,
            "details": "; ".join(details_parts)
        }
    }


def main(ctx, params):
    if params.get("_discover"):
        # Discover temperature sensors (only "temp" per check plugin)
        items = _discover_sensors(ctx, "temp")
        
        discovery_list = []
        for item in items:
            # Suggest empty params (Checkmk default is empty dict)
            discovery_list.append({
                "item": item,
                "params": {},
                "metrics": ["temperature"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }
    
    # Check mode: item is required
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "item is required",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Use temperature check logic
    return _check_temperature(ctx, params, item, "temp")