def main(ctx, params):
    if params.get("_discover"):
        # Discover humidity sensors via SNMP
        base_oid = ".1.3.6.1.4.1.13595.2.2.3.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            base_oid
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        
        discovered = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract value string
            val_str = ""
            if value_part.startswith("STRING: "):
                val_str = value_part[8:].strip('"')
            elif value_part.startswith("Integer32: "):
                val_str = value_part[11:]
            elif value_part.startswith("INTEGER: "):
                val_str = value_part[9:]
            elif value_part.startswith("Gauge32: "):
                val_str = value_part[9:]
            
            # Humidity threshold OID ends with ".2"
            if oid_end.endswith(".2"):
                parent_oid = oid_end.rsplit(".", 1)[0]
                sensor_loc = parent_oid.split(".")[-1]
                
                # Skip invalid sensor locations
                if sensor_loc.isdigit() and int(sensor_loc) > 0:
                    discovered.append({
                        "item": sensor_loc,
                        "params": {},
                        "metrics": ["humidity"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovered),
            "data": {"discovery": discovered},
        }
    
    # Check mode: single humidity sensor
    item = params.get("item", "")
    
    # Fetch humidity value (OID .1.3.6.1.4.1.13595.2.2.3.1.{item}.1)
    base_oid = ".1.3.6.1.4.1.13595.2.2.3.1"
    value_oid = base_oid + "." + item + ".1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), value_oid
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "humidity sensor not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    if len(lines) < 1:
        return {
            "changed": False,
            "msg": "no data received for sensor " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract value from response
    value_str = ""
    for line in lines:
        if "=" in line:
            parts = line.split("=", 1)
            if len(parts) == 2:
                val_part = parts[1].strip()
                if val_part.startswith("STRING: "):
                    value_str = val_part[8:].strip('"')
                elif val_part.startswith("Integer32: "):
                    value_str = val_part[11:]
                elif val_part.startswith("INTEGER: "):
                    value_str = val_part[9:]
                elif val_part.startswith("Gauge32: "):
                    value_str = val_part[9:]
                break
    
    # Convert to float with guard
    humidity = 0.0
    if value_str == "":
        return {
            "changed": False,
            "msg": "empty humidity value for sensor " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    humidity = float(value_str) if value_str.replace(".", "", 1).isdigit() else 0.0
    
    # Get thresholds from params
    warn = params.get("levels", (None, None))
    warn_low = warn[0]
    warn_high = warn[1]
    crit = params.get("levels_lower", (None, None))
    crit_low = crit[0]
    crit_high = crit[1]
    
    # Determine state
    state = "OK"
    msg_parts = ["Humidity %f %%" % humidity]
    
    # Check high levels
    if warn_high != None and humidity >= warn_high:
        state = "WARN"
    if crit_high != None and humidity >= crit_high:
        state = "CRIT"
    
    # Check low levels
    if warn_low != None and humidity <= warn_low:
        state = "WARN"
    if crit_low != None and humidity <= crit_low:
        state = "CRIT"
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": ""
        },
    }