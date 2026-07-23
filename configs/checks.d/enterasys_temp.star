def main(ctx, params):
    # Discovery mode: detect Enterasys devices and yield one item "Ambient"
    if params.get("_discover"):
        # Check if host is Enteresys by querying sysObjectID (.1.3.6.1.2.1.1.2.0)
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                       params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP error", "data": {"discovery": []}}
        
        # Look for Enterasys OIDs in sysObjectID
        sys_object_id = ""
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith(".1.3.6.1.2.1.1.2.0"):
                parts = stripped.split(" = ")
                if len(parts) == 2:
                    sys_object_id = parts[1].strip()
                break
        
        is_enterasys = (sys_object_id.startswith(".1.3.6.1.4.1.5624.2.1") or
                        sys_object_id.startswith(".1.3.6.1.4.1.5624.2.2"))
        
        if not is_enterasys:
            return {"changed": False, "msg": "not an Enterasys device", "data": {"discovery": []}}
        
        # Fetch the temperature OID (.1.3.6.1.4.1.52.4.1.1.8.1.1)
        temp_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
                            params.get("host", "localhost"), ".1.3.6.1.4.1.52.4.1.1.8.1.1"],
                           mutates=False)
        if temp_res.rc != 0 or not temp_res.stdout.strip():
            return {"changed": False, "msg": "no temperature data", "data": {"discovery": []}}
        
        # Extract value
        temp_value = ""
        for line in temp_res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith(".1.3.6.1.4.1.52.4.1.1.8.1.1"):
                parts = stripped.split(" = ")
                if len(parts) == 2:
                    val_str = parts[1].strip()
                    # Handle format: "INTEGER: 720" or "Gauge32: 720"
                    if ":" in val_str:
                        val_str = val_str.split(":", 1)[1].strip()
                    temp_value = val_str
                break
        
        # Only discover if sensor is supported (value != "0")
        if temp_value == "0" or temp_value == "":
            return {"changed": False, "msg": "sensor not supported", "data": {"discovery": []}}
        
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "Ambient", "params": {"levels": [30.0, 35.0]},
                                     "metrics": ["temp"]}]},
        }
    
    # Check mode for item "Ambient"
    item = params.get("item", "")
    if item != "Ambient":
        return {"changed": False, "msg": "unknown item", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch temperature value via SNMP
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-On",
                   params.get("host", "localhost"), ".1.3.6.1.4.1.52.4.1.1.8.1.1"],
                  mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP error", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    value_str = ""
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(".1.3.6.1.4.1.52.4.1.1.8.1.1"):
            parts = stripped.split(" = ")
            if len(parts) == 2:
                val_str = parts[1].strip()
                if ":" in val_str:
                    val_str = val_str.split(":", 1)[1].strip()
                value_str = val_str
            break
    
    # Sensor broken or not supported (value == "0")
    if value_str == "0" or value_str == "":
        return {"changed": False, "msg": "Sensor broken or not supported",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse value (Fahrenheit * 10) and convert to Celsius
    # Guard before conversion: only parse if string is numeric
    if not value_str.isdigit():
        return {"changed": False, "msg": "invalid temperature value", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp_f_dec = int(value_str)
    temp_f = temp_f_dec / 10.0
    temp_c = (temp_f - 32) * 5.0 / 9.0
    
    # Get thresholds (Checkmk default: levels=(30.0, 35.0))
    levels = params.get("levels", (30.0, 35.0))
    warn = levels[0] if isinstance(levels, list) else levels[0]
    crit = levels[1] if isinstance(levels, list) else levels[1]
    
    # Determine state (check_temperature uses upper levels: >= warn -> WARN, >= crit -> CRIT)
    if temp_c >= crit:
        state = "CRIT"
    elif temp_c >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    # Format message (Checkmk-style)
    msg = "Temperature: %f C" % temp_c
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temp": temp_c}, "details": ""}}
