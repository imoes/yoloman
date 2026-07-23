# Module for checkmk.gude_humidity: read-only SNMP humidity check

# Constants for thresholds (Checkmk defaults)
DEFAULT_LEVELS = (60.0, 70.0)  # (warn, crit)
DEFAULT_LEVELS_LOWER = (0.0, 0.0)

def _parse_snmp_line(line):
    # Parse a single snmpwalk line: ".1.3.6.1.4.1.28507.X.Y.1.6.1.1.Z = INTEGER: reading"
    if line == "":
        return None
    parts = line.split("=", 1)
    if len(parts) != 2:
        return None
    oid_part = parts[0].strip()
    value_part = parts[1].strip()
    # Get the OID end (last component)
    oid_components = oid_part.rsplit(".", 1)
    if len(oid_components) != 2:
        return None
    idx_str = oid_components[1]
    # Check if idx_str is a valid integer string
    if not idx_str.isdigit():
        return None
    index = int(idx_str)
    
    # Extract value: INTEGER: NNN or Gauge32: NNN, etc.
    raw_val = -999.9
    if value_part.startswith("INTEGER:"):
        value_str = value_part[len("INTEGER:"):].strip()
    elif value_part.startswith("Gauge32:"):
        value_str = value_part[len("Gauge32:"):].strip()
    elif value_part.startswith("INTEGER:"):
        value_str = value_part[len("INTEGER:"):].strip()
    else:
        return None
    
    if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
        raw_val = float(value_str)
    else:
        # Try parsing float directly
        return None
    
    return (index, raw_val)

def main(ctx, params):
    # Determine mode
    if params.get("_discover"):
        # DISCOVERY MODE: walk all humidity OIDs and discover active sensors
        # Base OIDs for detection: .1.3.6.1.4.1.28507.19, .38, .66, .67
        base_oids = [".1.3.6.1.4.1.28507.19.1.6.1.1", 
                     ".1.3.6.1.4.1.28507.38.1.6.1.1", 
                     ".1.3.6.1.4.1.28507.66.1.6.1.1", 
                     ".1.3.6.1.4.1.28507.67.1.6.1.1"]
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Collect all (index, reading) pairs
        all_entries = []
        for base in base_oids:
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base], mutates=False)
            if res.rc != 0:
                continue
            for line in res.stdout.splitlines():
                entry = _parse_snmp_line(line)
                if entry != None:
                    all_entries.append(entry)
        
        # Build section: {"Sensor <index>": reading/10} for valid entries
        section = {}
        for idx, val in all_entries:
            if val != -999.9:  # -999.9 means inactive sensor
                section["Sensor " + str(idx)] = val / 10.0
        
        # Build discovery list
        items = []
        for item_name in sorted(section.keys()):
            items.append({"item": item_name, "params": {"levels": DEFAULT_LEVELS, "levels_lower": DEFAULT_LEVELS_LOWER},
                          "metrics": ["humidity"]})
        
        return {"changed": False, "msg": "discovered %d humidity sensors" % len(items),
                "data": {"discovery": items}}
    
    # CHECK MODE: check a specific sensor item
    item = params.get("item", "")
    levels = params.get("levels", DEFAULT_LEVELS)
    levels_lower = params.get("levels_lower", DEFAULT_LEVELS_LOWER)
    warn_high = levels[0] if len(levels) >= 1 else 60.0
    crit_high = levels[1] if len(levels) >= 2 else 70.0
    warn_low = levels_lower[0] if len(levels_lower) >= 1 else 0.0
    crit_low = levels_lower[1] if len(levels_lower) >= 2 else 0.0
    
    # We need to find which sensor index corresponds to "item" (e.g. "Sensor 1")
    # Extract numeric index from item name "Sensor X"
    if not item.startswith("Sensor "):
        return {"changed": False, "msg": "invalid item format: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    idx_str = item[7:]
    if not idx_str.isdigit():
        return {"changed": False, "msg": "invalid sensor index in item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sensor_idx = int(idx_str)
    
    # Gather data via SNMP (same OIDs as discovery)
    base_oids = [".1.3.6.1.4.1.28507.19.1.6.1.1", 
                 ".1.3.6.1.4.1.28507.38.1.6.1.1", 
                 ".1.3.6.1.4.1.28507.66.1.6.1.1", 
                 ".1.3.6.1.4.1.28507.67.1.6.1.1"]
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Walk all OIDs to find the specific sensor reading
    reading = None
    for base in base_oids:
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base], mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            entry = _parse_snmp_line(line)
            if entry == None:
                continue
            idx = entry[0]
            raw_val = entry[1]
            if idx == sensor_idx:
                if raw_val != -999.9:
                    reading = raw_val / 10.0
                break
    
    # If reading not found or invalid
    if reading == None:
        return {"changed": False, "msg": "sensor not found or invalid: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Determine state and message
    state = "OK"
    if reading >= crit_high:
        state = "CRIT"
    elif reading >= warn_high:
        state = "WARN"
    elif reading <= crit_low:
        state = "CRIT"
    elif reading <= warn_low:
        state = "WARN"
    
    msg = "Humidity: %f %% " % reading
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"humidity": reading}, "details": ""}}