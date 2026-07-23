# SNMP OID constants for Kentix temperature sensors
OID_BASE_UPPER = ".1.3.6.1.4.1.37954.2.1.1"
OID_BASE_LOWER = ".1.3.6.1.4.1.37954.3.1.1"
OID_SENSORS = ["1", "2", "3"]

def _is_numeric(s):
    """Check if string represents a numeric value."""
    s = s.strip()
    if s == "":
        return False
    if s.startswith("-"):
        s = s[1:]
    if s == "":
        return False
    if s.count(".") > 1:
        return False
    for c in s:
        if c != "." and not c.isdigit():
            return False
    return True

def _parse_float(s):
    """Parse string to float safely; return None if invalid."""
    if not _is_numeric(s):
        return None
    # Starlark has no try/except, so we rely on built-in float() failing gracefully
    # In practice, since we validated the string, this won't fail
    return float(s)

def _snmpwalk(ctx, host, community, base_oid, oids):
    """Perform SNMP walk on base_oid+oid for each oid in oids list."""
    results = {}
    for i, oid_suffix in enumerate(oids):
        full_oid = base_oid + "." + oid_suffix
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, full_oid], mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            if value_part.startswith("STRING: "):
                value = value_part[8:].strip().strip('"')
            elif value_part.startswith("INTEGER: "):
                value = value_part[9:]
            elif value_part.startswith("Gauge32: "):
                value = value_part[9:]
            else:
                value = value_part
            # Extract index from end of OID
            idx = oid_part.rsplit('.', 1)[-1]
            if idx not in results:
                results[idx] = {}
            results[idx][i] = value
    return results

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode: collect all sensors
    if params.get("_discover"):
        sensors = {}
        
        # Try both base OIDs
        for base_oid in [OID_BASE_UPPER, OID_BASE_LOWER]:
            raw_data = _snmpwalk(ctx, host, community, base_oid, OID_SENSORS)
            for idx, values in raw_data.items():
                if len(values) >= 3:
                    # Validate values before conversion
                    val0 = values.get(0, "")
                    val1 = values.get(1, "")
                    val2 = values.get(2, "")
                    
                    # Parse values only if numeric
                    num0 = _parse_float(val0)
                    num1 = _parse_float(val1)
                    num2 = _parse_float(val2)
                    
                    if num0 != None and num1 != None and num2 != None:
                        reading = num0 / 10.0
                        lower_warn = num1 / 10.0
                        upper_warn = num2 / 10.0
                        
                        # Determine item name based on base OID used
                        if base_oid == OID_BASE_UPPER:
                            item_name = "LAN"
                        else:
                            item_name = "Rack"
                        
                        # Create item key to handle multiple sensors per type
                        key = "%s_%s" % (item_name, idx)
                        sensors[key] = {
                            "reading": reading,
                            "dev_levels": (upper_warn, upper_warn),
                            "dev_levels_lower": (lower_warn, lower_warn)
                        }
        
        discovery = []
        for item in sorted(sensors.keys()):
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["temperature"]
            })
        
        return {"changed": False, "msg": "discovered %d sensors" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode: evaluate one sensor
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Collect sensor data again (re-use same logic as discovery)
    sensors = {}
    for base_oid in [OID_BASE_UPPER, OID_BASE_LOWER]:
        raw_data = _snmpwalk(ctx, host, community, base_oid, OID_SENSORS)
        for idx, values in raw_data.items():
            if len(values) >= 3:
                # Validate values before conversion
                val0 = values.get(0, "")
                val1 = values.get(1, "")
                val2 = values.get(2, "")
                
                # Parse values only if numeric
                num0 = _parse_float(val0)
                num1 = _parse_float(val1)
                num2 = _parse_float(val2)
                
                if num0 != None and num1 != None and num2 != None:
                    reading = num0 / 10.0
                    lower_warn = num1 / 10.0
                    upper_warn = num2 / 10.0
                    
                    # Determine item name based on base OID used
                    if base_oid == OID_BASE_UPPER:
                        item_name = "LAN"
                    else:
                        item_name = "Rack"
                    
                    key = "%s_%s" % (item_name, idx)
                    sensors[key] = {
                        "reading": reading,
                        "dev_levels": (upper_warn, upper_warn),
                        "dev_levels_lower": (lower_warn, lower_warn)
                    }
    
    if item not in sensors:
        return {"changed": False, "msg": "sensor not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    sensor = sensors[item]
    reading = sensor["reading"]
    dev_levels = sensor["dev_levels"]
    dev_levels_lower = sensor["dev_levels_lower"]
    
    # Get thresholds from params, falling back to device levels
    warn = params.get("levels_upper", dev_levels[0])
    crit = params.get("levels_upper_critical", dev_levels[1])
    warn_lower = params.get("levels_lower", dev_levels_lower[0])
    crit_lower = params.get("levels_lower_critical", dev_levels_lower[1])
    
    # Determine state: CRIT if out of either upper or lower bounds, then WARN
    state = "OK"
    details = []
    
    # Upper bounds check
    if crit != None and reading >= crit:
        state = "CRIT"
        details.append("upper critical: %f" % crit)
    elif warn != None and reading >= warn:
        if state != "CRIT":
            state = "WARN"
        details.append("upper warning: %f" % warn)
    
    # Lower bounds check
    if crit_lower != None and reading <= crit_lower:
        state = "CRIT"
        details.append("lower critical: %f" % crit_lower)
    elif warn_lower != None and reading <= warn_lower:
        if state != "CRIT":
            state = "WARN"
        details.append("lower warning: %f" % warn_lower)
    
    # Build message
    msg = "Temperature: %f C" % reading
    if details:
        msg += ", " + ", ".join(details)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}