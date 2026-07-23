def main(ctx, params):
    # Constants for sensor types
    SENSOR_TYPE_HUMIDITY = "3"
    
    # Host and community for SNMP
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        # Fetch all sensor data via SNMP: type and value separately
        res_type = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.14848.2.1.2.1.3"
        ], mutates=False)
        
        res_val = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.14848.2.1.2.1.5"
        ], mutates=False)
        
        res_name = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.14848.2.1.2.1.2"
        ], mutates=False)
        
        # Parse type map
        type_map = {}
        if res_type.rc == 0:
            for line in res_type.stdout.split("\n"):
                if line == "" or "=" not in line:
                    continue
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_full = parts[0].strip()
                oid_end = oid_full.rsplit(".", 1)[-1]
                type_map[oid_end] = parts[1].strip()
        
        # Parse value map — guard before conversion
        val_map = {}
        if res_val.rc == 0:
            for line in res_val.stdout.split("\n"):
                if line == "" or "=" not in line:
                    continue
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_full = parts[0].strip()
                oid_end = oid_full.rsplit(".", 1)[-1]
                raw_val = parts[1].strip()
                # Guard: ensure numeric before conversion
                if raw_val.isdigit() or (raw_val.startswith("-") and raw_val[1:].isdigit()):
                    val_map[oid_end] = float(raw_val) / 10.0
        
        # Parse name map
        name_map = {}
        if res_name.rc == 0:
            for line in res_name.stdout.split("\n"):
                if line == "" or "=" not in line:
                    continue
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_full = parts[0].strip()
                oid_end = oid_full.rsplit(".", 1)[-1]
                v = parts[1].strip()
                if v.startswith('"') and v.endswith('"'):
                    v = v[1:-1]
                name_map[oid_end] = v
        
        # Collect humidity sensors
        out = []
        for oid_end, stype in type_map.items():
            if stype == SENSOR_TYPE_HUMIDITY and oid_end in val_map:
                val = val_map[oid_end]
                # Skip zero readings
                if val == 0.0:
                    continue
                item = oid_end + "." + SENSOR_TYPE_HUMIDITY
                out.append({
                    "item": item,
                    "params": {},
                    "metrics": ["humidity"],
                })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(out),
            "data": {"discovery": out},
        }
    
    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item required",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    parts = item.split(".")
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    oid_end = parts[0]
    sensor_type = parts[1]
    
    if sensor_type != SENSOR_TYPE_HUMIDITY:
        return {
            "changed": False,
            "msg": "not a humidity sensor",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Fetch humidity value
    res_val = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.14848.2.1.2.1.5." + oid_end
    ], mutates=False)
    
    if res_val.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    value_str = ""
    if res_val.stdout != "" and " = " in res_val.stdout:
        value_str = res_val.stdout.strip().split(" = ", 1)[-1].strip()
    
    humidity_val = 0.0
    if value_str != "":
        # Guard before float conversion
        if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
            humidity_val = float(value_str) / 10.0
    
    # Fetch sensor name
    res_name = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.14848.2.1.2.1.2." + oid_end
    ], mutates=False)
    
    name = "Sensor"
    if res_name.rc == 0 and res_name.stdout != "" and " = " in res_name.stdout:
        v = res_name.stdout.strip().split(" = ", 1)[-1].strip()
        if v.startswith('"') and v.endswith('"'):
            v = v[1:-1]
        if v != "":
            name = v
    
    # Extract thresholds
    warn_upper = None
    crit_upper = None
    levels = params.get("levels", [])
    if type(levels) == "list" and len(levels) == 2:
        warn_upper = levels[1]
    levels_upper = params.get("levels_upper", [])
    if type(levels_upper) == "list" and len(levels_upper) == 2:
        crit_upper = levels_upper[1]
    
    # Determine state: upper levels
    state = "OK"
    msg = ""
    if crit_upper != None and humidity_val >= crit_upper:
        state = "CRIT"
        msg = "Humidity %d%% (threshold >= %d%%)" % (int(humidity_val), int(crit_upper))
    elif warn_upper != None and humidity_val >= warn_upper:
        state = "WARN"
        msg = "Humidity %d%% (threshold >= %d%%)" % (int(humidity_val), int(warn_upper))
    else:
        msg = "Humidity %d%%" % int(humidity_val)
    
    details = "[%s] %s" % (name, msg)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity_val},
            "details": details,
        },
    }
