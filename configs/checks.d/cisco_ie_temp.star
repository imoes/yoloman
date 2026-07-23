# Module-level constants for SNMP OIDs and defaults
OID_BASE = ".1.3.6.1.4.1.9.9.832.1.24.1.3.6.1"
OID_TEMP_END = OID_BASE + ".1"  # OIDEnd() in discovery
OID_TEMP_VALUE = OID_BASE + ".5"  # cie1000SysutilStatusTemperatureMonitorTemperature

# Default thresholds (Checkmk temperature defaults)
DEFAULT_WARN = (25.0, 30.0)
DEFAULT_CRIT = (30.0, 35.0)

def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        # Get system description to verify it's an IE1000 device
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.1.0"],
                      mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 sensors",
                    "data": {"discovery": []}}
        
        # Check if it's an IE1000 device
        sys_desc = res.stdout.strip()
        if not sys_desc.startswith(".1.3.6.1.2.1.1.1.0 = STRING: ") or "IE1000" not in sys_desc:
            return {"changed": False, "msg": "discovered 0 sensors",
                    "data": {"discovery": []}}
        
        # Walk temperature sensors
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), OID_BASE],
                      mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 sensors",
                    "data": {"discovery": []}}
        
        # Parse snmpwalk output: "OID = STRING: value"
        items = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or " = " not in line:
                continue
            parts = line.split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0]
            value_part = parts[1]
            # Extract sensor ID from OID end
            sensor_id = oid_end.rsplit(".", 1)[-1]
            # Extract temperature value (STRING: NNN.N)
            if not value_part.startswith("STRING: "):
                continue
            temp_str = value_part[8:].strip()
            # Guard instead of try/except
            if temp_str.replace(".", "", 1).replace("-", "", 1).isdigit() or (temp_str.count(".") == 1 and temp_str.replace(".", "").replace("-", "", 1).isdigit()):
                items.append({"item": sensor_id, "params": {"levels": (25.0, 30.0)},
                              "metrics": ["temperature"]})
        
        return {"changed": False, "msg": "discovered %d sensors" % len(items),
                "data": {"discovery": items}}
    
    # CHECK MODE
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get temperature for this sensor
    oid = OID_BASE + "." + item + ".5"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid],
                  mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no temperature data for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse temperature value
    line = res.stdout.strip()
    if " = " not in line:
        return {"changed": False, "msg": "malformed response for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts = line.split(" = ")
    if len(parts) != 2:
        return {"changed": False, "msg": "malformed response for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_part = parts[1]
    if not value_part.startswith("STRING: "):
        return {"changed": False, "msg": "malformed response for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp_str = value_part[8:].strip()
    # Validate before converting
    temp_valid = False
    if temp_str.replace(".", "", 1).replace("-", "", 1).isdigit():
        temp_valid = True
    elif temp_str.count(".") == 1 and temp_str.replace(".", "").replace("-", "", 1).isdigit():
        temp_valid = True
    
    if not temp_valid:
        return {"changed": False, "msg": "invalid temperature value for sensor " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temperature = float(temp_str)
    
    # Get thresholds from params (Checkmk temperature ruleset format)
    levels = params.get("levels", DEFAULT_WARN)
    if type(levels) == "list" and len(levels) == 2:
        warn_upper = levels[0]
        warn_lower = levels[1]
        crit_upper = levels[0]
        crit_lower = levels[1]
    elif type(levels) == "list" and len(levels) == 4:
        warn_upper = levels[0]
        warn_lower = levels[1]
        crit_upper = levels[2]
        crit_lower = levels[3]
    else:
        warn_upper = DEFAULT_WARN[0]
        warn_lower = DEFAULT_WARN[1]
        crit_upper = DEFAULT_CRIT[0]
        crit_lower = DEFAULT_CRIT[1]
    
    # Determine state
    state = "OK"
    details = ""
    if temperature >= crit_upper:
        state = "CRIT"
        details = "Temperature is critically high: %f C" % temperature
    elif temperature >= warn_upper:
        state = "WARN"
        details = "Temperature is elevated: %f C" % temperature
    elif temperature <= crit_lower:
        state = "CRIT"
        details = "Temperature is critically low: %f C" % temperature
    elif temperature <= warn_lower:
        state = "WARN"
        details = "Temperature is low: %f C" % temperature
    
    if state == "OK":
        details = "Temperature: %f C" % temperature
    
    return {"changed": False,
            "msg": details,
            "data": {"state": state, "metrics": {"temperature": temperature}, "details": ""}}
