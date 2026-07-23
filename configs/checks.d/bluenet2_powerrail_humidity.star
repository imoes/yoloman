def main(ctx, params):
    # Constants for humidity check (from Checkmk plugin defaults)
    DEFAULT_WARN = 75.0
    DEFAULT_CRIT = 80.0
    DEFAULT_WARN_LOWER = 5.0
    DEFAULT_CRIT_LOWER = 8.0

    # Helper to extract sensor humidity values from snmpwalk output
    def parse_humidity_section(stdout):
        humidity_readings = {}
        lines = stdout.split("\n")
        for line in lines:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            oid = parts[0]
            value_str = parts[1]
            
            # Check for humidity sensor OID pattern (ends with .1.1.0 or .1.1.1)
            if oid.endswith(".1.1.0") or oid.endswith(".1.1.1") or oid.endswith(".1.1.2"):
                oid_parts = oid.split(".")
                if len(oid_parts) >= 12:
                    pdu_index_str = oid_parts[-12]
                    internal = oid_parts[-8]
                    external = oid_parts[-7]
                    
                    # Convert pdu_index_str to int safely
                    pdu_index = int(pdu_index_str) if pdu_index_str.isdigit() else 0
                    
                    if pdu_index == 0:
                        pdu_name = "Master"
                    else:
                        pdu_name = "PDU %s" % pdu_index
                    
                    sensor_name = "Sensor %s %s/%s" % (pdu_name, internal, external)
                    
                    # Guard instead of try/except
                    # Check if value_str is a valid number (allows decimal point and negative)
                    clean_str = value_str.replace(".", "", 1)
                    clean_str = clean_str.replace("-", "", 1)
                    if clean_str.isdigit():
                        raw_value = float(value_str)
                        humidity_value = raw_value / 100.0
                        humidity_readings[sensor_name] = humidity_value
        return humidity_readings

    # Discovery mode
    if params.get("_discover"):
        # Run snmpwalk on the humidity variable data section
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # OID base for variable data value (humidity)
        base_oid = ".1.3.6.1.4.1.31770.2.2.8.4.1.5"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        
        humidity_items = parse_humidity_section(res.stdout)
        items = []
        for item_name in humidity_items:
            items.append({
                "item": item_name,
                "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT, "warn_lower": DEFAULT_WARN_LOWER, "crit_lower": DEFAULT_CRIT_LOWER},
                "metrics": ["humidity"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get humidity data
    base_oid = ".1.3.6.1.4.1.31770.2.2.8.4.1.5"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    
    humidity_readings = parse_humidity_section(res.stdout)
    
    # Check if item exists
    if not (item in humidity_readings):
        return {
            "changed": False,
            "msg": "humidity sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get threshold parameters with defaults
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    warn_lower = params.get("warn_lower", DEFAULT_WARN_LOWER)
    crit_lower = params.get("crit_lower", DEFAULT_CRIT_LOWER)
    
    # Get humidity value
    humidity_value = humidity_readings[item]
    
    # Determine state based on thresholds
    state = "OK"
    details_parts = []
    
    # Check upper bounds
    if humidity_value >= crit:
        state = "CRIT"
        details_parts.append("humidity above critical threshold (%f%%)" % crit)
    elif humidity_value >= warn:
        state = "WARN"
        details_parts.append("humidity above warning threshold (%f%%)" % warn)
    
    # Check lower bounds
    if humidity_value <= crit_lower:
        state = "CRIT"
        details_parts.append("humidity below critical threshold (%f%%)" % crit_lower)
    elif humidity_value <= warn_lower:
        if state == "OK":
            state = "WARN"
        details_parts.append("humidity below warning threshold (%f%%)" % warn_lower)
    
    # Format message
    details = "; ".join(details_parts) if details_parts else ""
    msg = "Humidity: %f%%" % humidity_value
    if details:
        msg += ", " + details
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity_value},
            "details": details
        }
    }