# Module constants (defined at top level as required)
AKCP_TEMP_CHECK_DEFAULT_PARAMETERS = {
    "levels": (32.0, 35.0),
}

# SNMP OID mapping for akcp_exp_temp section
SNMP_BASE_OID = ".1.3.6.1.4.1.3854.2.3.2.1"
OID_DESCRIPTION = "2"
OID_DEGREE = "4"
OID_UNIT = "5"
OID_STATUS = "6"
OID_LOW_CRIT = "9"
OID_LOW_WARN = "10"
OID_HIGH_WARN = "11"
OID_HIGH_CRIT = "12"
OID_DEGREE_RAW = "19"
OID_ONLINE = "8"

# Sensor status states mapping (from Checkmk source)
AKCP_SENSOR_LEVEL_STATES = {
    "1": ("no status", 2),
    "2": ("normal", 0),
    "3": ("high warning", 1),
    "4": ("high critical", 2),
    "5": ("low warning", 1),
    "6": ("low critical", 2),
    "7": ("sensor error", 2),
}


def main(ctx, params):
    if params.get("_discover") == True:
        return _discovery_mode(ctx, params)

    return _check_mode(ctx, params)


def _discovery_mode(ctx, params):
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        SNMP_BASE_OID
    ], mutates=False)
    
    items = []
    # Parse snmpwalk output: OID = TYPE: value
    lines = res.stdout.splitlines()
    # Build lookup tables by OID suffix
    descriptions = {}
    online_states = {}
    
    for line in lines:
        if line.find("=") < 0:
            continue
        parts = line.split("=", 1)
        oid = parts[0].strip()
        value = parts[1].strip().lstrip(" ").lstrip('"').rstrip('"').rstrip()
        
        # Extract suffix after base OID
        if oid.startswith(SNMP_BASE_OID + "."):
            suffix = oid[len(SNMP_BASE_OID) + 1:]
            
            if suffix == OID_DESCRIPTION:
                descriptions[value] = True
            elif suffix == OID_ONLINE:
                # Extract numeric index from OID
                idx = oid.rsplit(".", 1)[-1]
                online_states[idx] = value
    
    # Re-parse to correlate items with online status
    sensor_data = {}
    for line in lines:
        if line.find("=") < 0:
            continue
        parts = line.split("=", 1)
        oid = parts[0].strip()
        value = parts[1].strip().lstrip(" ").lstrip('"').rstrip('"').rstrip()
        
        if oid.startswith(SNMP_BASE_OID + "."):
            suffix = oid[len(SNMP_BASE_OID) + 1:]
            idx = oid.rsplit(".", 1)[-1]
            
            # Initialize sensor data dict if not exists
            if idx not in sensor_data:
                sensor_data[idx] = {}
            
            if suffix == OID_DESCRIPTION:
                sensor_data[idx]["description"] = value
            elif suffix == OID_ONLINE:
                sensor_data[idx]["online"] = value
    
    # Build items list - only online sensors (online == "1")
    for idx, data in sensor_data.items():
        if data.get("online") == "1":
            desc = data.get("description", "")
            if desc != "":
                items.append({
                    "item": desc,
                    "params": AKCP_TEMP_CHECK_DEFAULT_PARAMETERS,
                    "metrics": ["temperature"]
                })
    
    return {
        "changed": False,
        "msg": "discovered %d temperature sensors" % len(items),
        "data": {"discovery": items},
    }


def _check_mode(ctx, params):
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        SNMP_BASE_OID
    ], mutates=False)
    
    # Parse snmpwalk output
    lines = res.stdout.splitlines()
    sensor_data = {}
    
    for line in lines:
        if line.find("=") < 0:
            continue
        parts = line.split("=", 1)
        oid = parts[0].strip()
        value = parts[1].strip().lstrip(" ").lstrip('"').rstrip('"').rstrip()
        
        if oid.startswith(SNMP_BASE_OID + "."):
            suffix = oid[len(SNMP_BASE_OID) + 1:]
            idx = oid.rsplit(".", 1)[-1]
            
            # Initialize sensor data dict if not exists
            if idx not in sensor_data:
                sensor_data[idx] = {}
            
            if suffix == OID_DESCRIPTION:
                sensor_data[idx]["description"] = value
            elif suffix == OID_DEGREE:
                sensor_data[idx]["degree"] = value
            elif suffix == OID_UNIT:
                sensor_data[idx]["unit"] = value
            elif suffix == OID_STATUS:
                sensor_data[idx]["status"] = value
            elif suffix == OID_LOW_CRIT:
                sensor_data[idx]["low_crit"] = value
            elif suffix == OID_LOW_WARN:
                sensor_data[idx]["low_warn"] = value
            elif suffix == OID_HIGH_WARN:
                sensor_data[idx]["high_warn"] = value
            elif suffix == OID_HIGH_CRIT:
                sensor_data[idx]["high_crit"] = value
            elif suffix == OID_DEGREE_RAW:
                sensor_data[idx]["degreeraw"] = value
            elif suffix == OID_ONLINE:
                sensor_data[idx]["online"] = value
    
    # Find the item
    item_found = False
    for idx, data in sensor_data.items():
        if data.get("description") == item:
            item_found = True
            
            # Check online status
            if data.get("online") != "1":
                return {
                    "changed": False,
                    "msg": "sensor is offline",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""},
                }
            
            status = data.get("status", "0")
            if status == "1" or status == "7":
                state_name, state_code = AKCP_SENSOR_LEVEL_STATES[status]
                return {
                    "changed": False,
                    "msg": "State: " + state_name,
                    "data": {"state": ["OK", "WARN", "CRIT", "UNKNOWN"][state_code], "metrics": {}, "details": ""},
                }
            
            # Get temperature reading
            unit = data.get("unit", "C")
            degreeraw = data.get("degreeraw", "0")
            degree = data.get("degree", "")
            
            temperature = 0.0
            if degreeraw != "" and degreeraw != "0":
                temperature = float(degreeraw) / 10.0
            elif degree == "":
                return {
                    "changed": False,
                    "msg": "Temperature information not found",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            else:
                temperature = float(degree)
            
            # Normalize unit
            unit_normalized = "c"
            if unit.isdigit():
                unit_normalized = "f" if unit == "0" else "c"
                low_c = float(data.get("low_crit", "0"))
                low_w = float(data.get("low_warn", "0"))
                high_w = float(data.get("high_warn", "0"))
                high_c = float(data.get("high_crit", "0"))
            else:
                unit_normalized = unit.lower()
                high_crit_val = int(data.get("high_crit", "0"))
                if high_crit_val > 100:
                    low_c = float(data.get("low_crit", "0")) / 10.0
                    low_w = float(data.get("low_warn", "0")) / 10.0
                    high_w = float(data.get("high_warn", "0")) / 10.0
                    high_c = float(data.get("high_crit", "0")) / 10.0
                else:
                    low_c = float(data.get("low_crit", "0"))
                    low_w = float(data.get("low_warn", "0"))
                    high_w = float(data.get("high_warn", "0"))
                    high_c = float(data.get("high_crit", "0"))
            
            # Get thresholds from params
            levels = params.get("levels", AKCP_TEMP_CHECK_DEFAULT_PARAMETERS["levels"])
            high_w_param = levels[0]
            high_c_param = levels[1]
            
            levels_lower = params.get("levels_lower", (None, None))
            low_w_param = levels_lower[0]
            low_c_param = levels_lower[1]
            
            # Determine state based on thresholds
            state = "OK"
            
            # Check high thresholds
            if high_w_param != None and temperature >= high_w_param:
                if high_c_param != None and temperature >= high_c_param:
                    state = "CRIT"
                else:
                    state = "WARN"
            
            # Check low thresholds if provided
            if low_w_param != None and temperature <= low_w_param:
                if low_c_param != None and temperature <= low_c_param:
                    state = "CRIT"
                elif state == "OK":
                    state = "WARN"
            
            # Build message
            unit_label = "C"
            if unit_normalized == "f":
                unit_label = "F"
            msg = "Temperature: %f %s" % (temperature, unit_label)
            
            return {
                "changed": False,
                "msg": msg,
                "data": {
                    "state": state,
                    "metrics": {"temperature": temperature},
                    "details": "",
                },
            }
    
    # Item not found
    if item_found == False:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    return {
        "changed": False,
        "msg": "unexpected error",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }
