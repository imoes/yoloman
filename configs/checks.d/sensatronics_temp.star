def main(ctx, params):
    # Get SNMP parameters from params or use sensible defaults
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode: enumerate all sensors
    if params.get("_discover"):
        # Fetch all temperature sensor data via SNMP
        sensors = []
        for table in range(16):
            # Walk both OID branches for this table
            name_res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On",
                host, ".1.3.6.1.4.1.16174.1.1.1.3.%d.1.0" % table
            ], mutates=False)
            
            value_res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-On",
                host, ".1.3.6.1.4.1.16174.1.1.1.3.%d.2.0" % table
            ], mutates=False)
            
            # Parse name and value lines into sensor entries
            names = _parse_snmp_output(name_res.stdout)
            values = _parse_snmp_output(value_res.stdout)
            
            # Create sensor entries for each matched name/value pair
            for oid_part in names:
                name = names[oid_part]
                if oid_part in values:
                    value_str = values[oid_part]
                    # Guard instead of try: check if value is numeric before converting
                    value_candidate = float(value_str) if value_str.replace(".", "", 1).replace("-", "", 1).isdigit() else None
                    if value_candidate != None:
                        item = "%d.%s" % (table, name)
                        sensors.append({
                            "item": item,
                            "params": {"levels": [23.0, 25.0]},
                            "metrics": ["temperature"]
                        })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(sensors),
            "data": {"discovery": sensors}
        }
    
    # Check mode: examine one specific sensor item
    item = params.get("item", "")
    if item == None:
        item = ""
    
    # Parse item into table and sensor name (format: "table.sensor_name")
    parts = item.split(".", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    table_str = parts[0]
    # Guard instead of try: check if table is numeric before converting
    table = int(table_str) if table_str.isdigit() or (table_str.startswith("-") and table_str[1:].isdigit()) else None
    if table == None:
        return {
            "changed": False,
            "msg": "invalid table number in item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    sensor_name = parts[1]
    
    # Fetch the specific sensor value
    value_oid = ".1.3.6.1.4.1.16174.1.1.1.3.%d.2.0" % table
    value_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, value_oid
    ], mutates=False)
    
    # Check if we got a result
    if value_res.rc != 0 or value_res.stdout == "":
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    values = _parse_snmp_output(value_res.stdout)
    
    # Get the value (look for the exact OID match)
    found = False
    reading = None
    for oid_part in values:
        if oid_part.endswith(".1.3.6.1.4.1.16174.1.1.1.3.%d.2.0" % table):
            value_str = values[oid_part]
            # Guard instead of try: check if value is numeric before converting
            if value_str != None and value_str != "":
                value_candidate = float(value_str) if value_str.replace(".", "", 1).replace("-", "", 1).isdigit() else None
                if value_candidate != None:
                    reading = value_candidate
                    found = True
                    break
    
    if not found or reading == None:
        return {
            "changed": False,
            "msg": "cannot parse temperature value for sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get thresholds from params, use Checkmk defaults if not provided
    levels = params.get("levels", [23.0, 25.0])
    warn = 23.0
    crit = 25.0
    if isinstance(levels, list) and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    
    # Determine state based on thresholds (higher is worse)
    if reading >= crit:
        state = "CRIT"
    elif reading >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "Temperature: %f C" % reading,
        "data": {
            "state": state,
            "metrics": {"temperature": reading},
            "details": ""
        }
    }

def _parse_snmp_output(output):
    """Parse SNMP output lines into {oid_part: value} mapping."""
    result = {}
    if output == None:
        return result
    
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        
        # SNMP output format: OID = TYPE: value
        eq_pos = line.find("=")
        if eq_pos == -1:
            continue
        
        oid_part = line[:eq_pos].strip()
        value_part = line[eq_pos+1:].strip()
        
        # Extract actual value after type indicator
        colon_pos = value_part.find(":")
        if colon_pos != -1:
            value = value_part[colon_pos+1:].strip()
        else:
            value = value_part
        
        result[oid_part] = value
    
    return result