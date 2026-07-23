# Top-level constants
DEFAULT_LEVELS_UPPER = (20.0, 20.0)
DEFAULT_LEVELS_LOWER = (-20.0, -20.0)

def _get_model_data(section):
    return [section[0], section[1] if section[1] else section[3], section[2] if section[2] else section[4]]

def _snmp_walk(ctx, community, host, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return []
    lines = res.stdout.splitlines()
    result = []
    for line in lines:
        parts = line.strip().split(" = ", 1)
        if len(parts) == 2:
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract value after colon (TYPE: value)
            if ": " in value_part:
                value = value_part.split(": ", 1)[1].strip()
            else:
                value = value_part.strip()
            result.append((oid_part, value))
    return result

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # SNMP section OIDs for wagner_titanus_topsense
    base_section0 = ".1.3.6.1.2.1.1"
    base_section1 = ".1.3.6.1.4.1.34187.21501.1.1"
    base_section2 = ".1.3.6.1.4.1.34187.21501.2.1"
    base_section3 = ".1.3.6.1.4.1.34187.74195.1.1"
    base_section4 = ".1.3.6.1.4.1.34187.74195.2.1"
    
    # Collect all SNMP sections
    section0 = _snmp_walk(ctx, community, host, base_section0)
    section1 = _snmp_walk(ctx, community, host, base_section1)
    section2 = _snmp_walk(ctx, community, host, base_section2)
    section3 = _snmp_walk(ctx, community, host, base_section3)
    section4 = _snmp_walk(ctx, community, host, base_section4)
    
    # Parse into section structure
    section = [section0, section1, section2, section3, section4]
    
    # Discovery mode
    if params.get("_discover"):
        out = []
        # Check if any of the two device types are detected
        # Device type detection based on sysObjectID (.1.3.6.1.2.1.1.2.0)
        sys_objectid = ""
        for oid, value in section[0]:
            if oid == ".1.3.6.1.2.1.1.2.0":
                sys_objectid = value
                break
        if sys_objectid in [".1.3.6.1.4.1.34187.21501", ".1.3.6.1.4.1.34187.74195"]:
            # Airflow deviation: items "1" and "2"
            for item in ["1", "2"]:
                out.append({
                    "item": item,
                    "params": {
                        "levels_upper": DEFAULT_LEVELS_UPPER,
                        "levels_lower": DEFAULT_LEVELS_LOWER,
                    },
                    "metrics": ["airflow_deviation"]
                })
        return {"changed": False, "msg": "discovered %d airflow deviation detectors" % len(out),
                "data": {"discovery": out}}
    
    # Check mode
    item = params.get("item", "")
    if item not in ["1", "2"]:
        return {"changed": False, "msg": "Airflow Deviation Detector %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get model data
    parsed = _get_model_data(section)
    
    # Check if we have section2 data
    if len(parsed) < 3 or len(parsed[2]) == 0:
        return {"changed": False, "msg": "No SNMP data available for airflow deviation",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Airflow deviation indices: item "1" -> index 4, item "2" -> index 5
    idx = 4 if item == "1" else 5
    
    # Extract airflow deviation value
    airflow_deviation_str = ""
    if len(parsed[2][0]) > idx:
        airflow_deviation_str = parsed[2][0][idx]
    
    if airflow_deviation_str == "" or not airflow_deviation_str.replace('.', '').lstrip('-').isdigit():
        return {"changed": False, "msg": "Airflow deviation value not available for detector %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    airflow_deviation = float(airflow_deviation_str)
    
    # Get thresholds
    levels_upper = params.get("levels_upper", DEFAULT_LEVELS_UPPER)
    levels_lower = params.get("levels_lower", DEFAULT_LEVELS_LOWER)
    warn_upper = levels_upper[0] if isinstance(levels_upper, tuple) else 20.0
    crit_upper = levels_upper[1] if isinstance(levels_upper, tuple) else 20.0
    warn_lower = levels_lower[0] if isinstance(levels_lower, tuple) else -20.0
    crit_lower = levels_lower[1] if isinstance(levels_lower, tuple) else -20.0
    
    # Determine state based on thresholds
    if airflow_deviation >= crit_upper or airflow_deviation <= crit_lower:
        state = "CRIT"
    elif airflow_deviation >= warn_upper or airflow_deviation <= warn_lower:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    msg = "%s%% Airflow deviation" % ("%f" % airflow_deviation)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"airflow_deviation": airflow_deviation}, "details": ""}}