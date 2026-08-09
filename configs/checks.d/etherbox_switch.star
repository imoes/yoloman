def main(ctx, params):
    # Constants for sensor types
    SENSOR_TYPE_TEMP = "1"
    SENSOR_TYPE_HUMIDITY = "3"
    SENSOR_TYPE_SWITCH = "4"
    SENSOR_TYPE_SMOKE = "6"
    SENSOR_TYPE_NOSENSOR = "0"
    SENSOR_TYPE_VOLTAGE = "5"
    
    # SNMP base OID for etherbox
    SNMP_BASE = ".1.3.6.1.4.1.14848.2.1"
    
    # Discovery mode
    if params.get("_discover"):
        # Discover all sensor items
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            SNMP_BASE + ".1.2.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        
        # Parse snmpwalk output: OID = TYPE: value
        sensor_items = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            # Extract the index from OID (e.g., .1.3.6.1.4.1.14848.2.1.2.1.1.1.2.1.1.2)
            oid_parts = oid_part.split(".")
            if len(oid_parts) < 16:
                continue
            # Index is the last part before the value (1-indexed)
            index = oid_parts[-1]
            
            # Parse value_part: "Integer: N" or "STRING: name"
            value_split = value_part.split(": ")
            if len(value_split) < 2:
                continue
            sensor_type = value_split[1]
            # Get numeric type if it's an integer
            if value_split[0].startswith("Integer"):
                sensor_type = value_split[1]
            else:
                # Try to extract numeric type from string value
                sensor_type = sensor_type.strip()
            
            # Filter for valid sensor types
            if sensor_type not in ["1", "2", "3", "4", "5", "6"]:
                continue
            
            # Get name for this sensor index
            name_oid = SNMP_BASE + ".1.2.1." + index + ".2"
            name_res = ctx.run([
                "snmpget", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), name_oid
            ], mutates=False)
            
            name = "unknown"
            if name_res.rc == 0:
                name_line = name_res.stdout.strip()
                if name_line:
                    name_parts = name_line.split(" = ")
                    if len(name_parts) >= 2:
                        value_parts = name_parts[1].split(": ")
                        if len(value_parts) >= 2:
                            name = value_parts[1]
            
            # Get value for this sensor index
            value_oid = SNMP_BASE + ".1.2.1." + index + ".5"
            value_res = ctx.run([
                "snmpget", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), value_oid
            ], mutates=False)
            
            value = 0
            if value_res.rc == 0:
                value_line = value_res.stdout.strip()
                if value_line:
                    value_parts = value_line.split(" = ")
                    if len(value_parts) >= 2:
                        val_content = value_parts[1].split(": ")
                        if len(val_content) >= 2 and val_content[1].isdigit():
                            value = int(val_content[1])
            
            # Skip sensors with value 0 for temp/humidity (inactive)
            if sensor_type in [SENSOR_TYPE_TEMP, SENSOR_TYPE_HUMIDITY] and value == 0:
                continue
            
            item = index + "." + sensor_type
            sensor_items[item] = {"name": name, "type": sensor_type, "value": value}
        
        # Build discovery list with suggested default parameters
        discovery_items = []
        for item in sorted(sensor_items.keys()):
            sensor = sensor_items[item]
            sensor_type = sensor["type"]
            
            # Suggested params based on sensor type
            suggested_params = {}
            if sensor_type == SENSOR_TYPE_TEMP:
                suggested_params = {"warn": 25, "crit": 30}
            elif sensor_type == SENSOR_TYPE_HUMIDITY:
                suggested_params = {"warn": 60, "crit": 80}
            elif sensor_type == SENSOR_TYPE_SWITCH:
                suggested_params = {"state": "ignore"}
            elif sensor_type == SENSOR_TYPE_SMOKE:
                suggested_params = {"smoke_handling": ("binary", (0, 2))}
            elif sensor_type == SENSOR_TYPE_VOLTAGE:
                suggested_params = {"levels": ("no_levels", None)}
            
            metrics = []
            if sensor_type == SENSOR_TYPE_TEMP:
                metrics = ["temp"]
            elif sensor_type == SENSOR_TYPE_HUMIDITY:
                metrics = ["humidity"]
            elif sensor_type == SENSOR_TYPE_SWITCH:
                metrics = ["switch_contact"]
            elif sensor_type == SENSOR_TYPE_SMOKE:
                metrics = ["smoke"]
            elif sensor_type == SENSOR_TYPE_VOLTAGE:
                metrics = ["voltage"]
            
            discovery_items.append({
                "item": item,
                "params": suggested_params,
                "metrics": metrics
            })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode - single item
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse item format: index.sensor_type
    item_parts = item.split(".")
    if len(item_parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format (expected index.type)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    index, sensor_type = item_parts
    
    # Get sensor data via SNMP
    # First get sensor name
    name_oid = SNMP_BASE + ".1.2.1." + index + ".2"
    name_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), name_oid
    ], mutates=False)
    
    name = "unknown"
    if name_res.rc == 0:
        name_line = name_res.stdout.strip()
        if name_line:
            name_parts = name_line.split(" = ")
            if len(name_parts) >= 2:
                value_parts = name_parts[1].split(": ")
                if len(value_parts) >= 2:
                    name = value_parts[1]
    
    # Get sensor value
    value_oid = SNMP_BASE + ".1.2.1." + index + ".5"
    value_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), value_oid
    ], mutates=False)
    
    value = 0
    if value_res.rc == 0:
        value_line = value_res.stdout.strip()
        if value_line:
            value_parts = value_line.split(" = ")
            if len(value_parts) >= 2:
                val_content = value_parts[1].split(": ")
                if len(val_content) >= 2 and val_content[1].isdigit():
                    value = int(val_content[1])
    
    # Apply sensor-specific logic
    if sensor_type == SENSOR_TYPE_TEMP:
        temp = value / 10.0
        # Use default temperature levels if not provided
        warn = params.get("warn", 25.0)
        crit = params.get("crit", 30.0)
        state = "OK"
        msg = "%s temperature %f C" % (name, temp)
        if temp >= crit:
            state = "CRIT"
            msg = "%s temperature %f C (>= %f C)" % (name, temp, crit)
        elif temp >= warn:
            state = "WARN"
            msg = "%s temperature %f C (>= %f C)" % (name, temp, warn)
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state,
                "metrics": {"temp": temp},
                "details": ""
            }
        }
    
    elif sensor_type == SENSOR_TYPE_HUMIDITY:
        humidity_val = value / 10.0
        # Use default humidity levels if not provided
        warn = params.get("warn", 60.0)
        crit = params.get("crit", 80.0)
        state = "OK"
        msg = "%s humidity %f %%" % (name, humidity_val)
        if humidity_val >= crit:
            state = "CRIT"
            msg = "%s humidity %f %% (>= %f %%)" % (name, humidity_val, crit)
        elif humidity_val >= warn:
            state = "WARN"
            msg = "%s humidity %f %% (>= %f %%)" % (name, humidity_val, warn)
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state,
                "metrics": {"humidity": humidity_val},
                "details": ""
            }
        }
    
    elif sensor_type == SENSOR_TYPE_SWITCH:
        switch_state = "open" if value == 1000 else "closed"
        expected_state = params.get("state", "ignore")
        state = "OK"
        extra_info = ""
        if expected_state != "ignore" and switch_state != expected_state:
            state = "CRIT"
            extra_info = ", should be %s" % expected_state
        msg = "[%s] Switch contact %s%s" % (name, switch_state, extra_info)
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state,
                "metrics": {"switch_contact": value},
                "details": ""
            }
        }
    
    elif sensor_type == SENSOR_TYPE_SMOKE:
        smoke_handling = params.get("smoke_handling", ("binary", (0, 2)))
        if smoke_handling[0] == "binary":
            no_smoke_state, smoke_state = smoke_handling[1]
            if value == 0:
                state = "OK"
                msg = "[%s] No smoke detected" % name
            else:
                state = "CRIT" if smoke_state == 2 else "WARN"
                msg = "[%s] Smoke detected" % name
        else:  # levels
            levels = smoke_handling[1]
            state = "OK"
            if levels and len(levels) > 0:
                warn_level = levels[0] if levels[0] != None else None
                crit_level = levels[1] if len(levels) > 1 and levels[1] != None else None
                if crit_level != None and value >= crit_level:
                    state = "CRIT"
                elif warn_level != None and value >= warn_level:
                    state = "WARN"
            msg = "[%s] Smoke level %d" % (name, value)
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state,
                "metrics": {"smoke": value},
                "details": ""
            }
        }
    
    elif sensor_type == SENSOR_TYPE_NOSENSOR:
        return {
            "changed": False,
            "msg": "[%s] no sensor connected" % name,
            "data": {
                "state": "OK",
                "metrics": {},
                "details": ""
            }
        }
    
    elif sensor_type == SENSOR_TYPE_VOLTAGE:
        voltage_val = value
        # Default: no levels
        levels = params.get("levels", ("no_levels", None))
        state = "OK"
        if levels and len(levels) > 0 and levels[0] == "no_levels":
            msg = "[%s] %f V" % (name, voltage_val / 1000.0)
        else:
            warn = None
            crit = None
            if levels and len(levels) > 1 and levels[1] != None:
                warn = levels[1][0] if len(levels[1]) > 0 else None
                crit = levels[1][1] if len(levels[1]) > 1 else None
            if crit != None and voltage_val >= crit:
                state = "CRIT"
                msg = "[%s] %f V (>= %f V)" % (name, voltage_val / 1000.0, crit / 1000.0)
            elif warn != None and voltage_val >= warn:
                state = "WARN"
                msg = "[%s] %f V (>= %f V)" % (name, voltage_val / 1000.0, warn / 1000.0)
            else:
                msg = "[%s] %f V" % (name, voltage_val / 1000.0)
        return {
            "changed": False,
            "msg": msg,
            "data": {
                "state": state,
                "metrics": {"voltage": voltage_val / 1000.0},
                "details": ""
            }
        }
    
    else:
        return {
            "changed": False,
            "msg": "unknown sensor type: %s" % sensor_type,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
