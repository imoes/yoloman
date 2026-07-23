# Constants defined at module top level (required for Starlark)
AKCP_TEMP_CHECK_DEFAULT_PARAMETERS = {
    "levels": (32.0, 35.0),
}

# SNMP OID mappings (base OIDs for the two device families)
OID_BASE_AKCP = ".1.3.6.1.4.1.3854.1.2.2.1.16.1"
OID_BASE_SP2PLUS = ".1.3.6.1.4.1.3854.3.5.2.1"

# Sensor status mappings
AKCP_SENSOR_LEVEL_STATES = {
    "1": (2, "no status"),
    "2": (0, "normal"),
    "3": (1, "high warning"),
    "4": (2, "high critical"),
    "5": (1, "low warning"),
    "6": (2, "low critical"),
    "7": (2, "sensor error"),
}

def _normalize_unit(unit):
    """Normalize temperature unit to 'c' or 'f'"""
    if unit.isdigit():
        return "f" if unit == "0" else "c"
    return unit.lower()

def _parse_temperature_value(val_str):
    """Parse temperature value string to float, return None if invalid"""
    if not val_str or val_str == "":
        return None
    # Check if string is a valid number (including negative)
    if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
        return float(val_str)
    return None

def _normalize_thresholds(low_crit, low_warn, high_warn, high_crit, unit):
    """Normalize temperature thresholds based on device format"""
    # Check if values are in *10 format (typical for F/C devices with values > 100)
    high_crit_val = _parse_temperature_value(high_crit)
    high_warn_val = _parse_temperature_value(high_warn)
    
    if high_crit_val != None and high_warn_val != None:
        # If values are > 100, they are in *10 format
        if high_crit_val > 100 or high_warn_val > 100:
            return (
                _parse_temperature_value(low_crit) / 10.0 if low_crit else None,
                _parse_temperature_value(low_warn) / 10.0 if low_warn else None,
                _parse_temperature_value(high_warn) / 10.0 if high_warn else None,
                _parse_temperature_value(high_crit) / 10.0 if high_crit else None
            )
    
    # Otherwise, use values directly
    return (
        _parse_temperature_value(low_crit),
        _parse_temperature_value(low_warn),
        _parse_temperature_value(high_warn),
        _parse_temperature_value(high_crit)
    )

def main(ctx, params):
    if params.get("_discover"):
        # DISCOVERY MODE
        # Detect device type via SNMP sysObjectID
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), 
                      "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], 
                      mutates=False)
        
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "SNMP probe failed",
                    "data": {"discovery": []}}
        
        sys_oid = res.stdout.strip().split(" = ")[-1].strip()
        
        # Determine base OID based on device family
        base_oid = OID_BASE_AKCP
        if ".1.3.6.1.4.1.3854" in sys_oid:
            # Check for SP2PLUS (has .1.3.6.1.4.1.3854.3.* but not .1.3.6.1.4.1.3854.2.*)
            # For simplicity, we assume standard AKCP if not explicitly SP2PLUS
            pass
        
        # Walk the temperature section
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                      "-On", params.get("host", "localhost"), base_oid],
                      mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        
        # Parse SNMP walk output
        lines = res.stdout.splitlines()
        sensors = []
        
        # For simplicity, use snmpget for each sensor index starting from 1
        idx = 1
        for _ in range(100):  # reasonable max sensors
            # Get description
            res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                          "-On", params.get("host", "localhost"), 
                          "%s.%d" % (base_oid, idx)], 
                          mutates=False)
            
            if res.rc != 0 or "No Such" in res.stdout:
                break
            
            desc = res.stdout.split(" = ")[-1].strip()
            if not desc:
                break
            
            # Check if online status is "1"
            online_oid = "%s.%d" % (base_oid, idx + 4)
            res_online = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                 "-On", params.get("host", "localhost"), online_oid],
                                 mutates=False)
            
            if res_online.rc == 0 and " = " in res_online.stdout:
                online_val = res_online.stdout.split(" = ")[-1].strip()
                if online_val == "1":
                    sensors.append({
                        "item": desc,
                        "params": {"levels": AKCP_TEMP_CHECK_DEFAULT_PARAMETERS["levels"]},
                        "metrics": ["temperature"]
                    })
            
            idx += 1
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(sensors),
            "data": {"discovery": sensors}
        }
    
    # CHECK MODE
    item = params.get("item", "")
    
    # Detect device type
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                  "-On", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], 
                  mutates=False)
    
    sys_oid = ""
    if res.rc == 0 and res.stdout and "=" in res.stdout:
        sys_oid = res.stdout.split(" = ")[-1].strip()
    
    # Determine base OID
    base_oid = OID_BASE_AKCP
    if ".1.3.6.1.4.1.3854.3.5" in sys_oid:
        base_oid = OID_BASE_SP2PLUS
    
    # Get all fields for the item
    # First, find the index for this item by checking each sensor
    idx = 1
    sensor_data = None
    
    for _ in range(100):
        # Get description
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                      "-On", params.get("host", "localhost"), 
                      "%s.%d" % (base_oid, idx)], 
                      mutates=False)
        
        if res.rc != 0 or "No Such" in res.stdout:
            break
        
        desc = res.stdout.split(" = ")[-1].strip()
        if desc == item:
            # Get online status first
            online_oid = "%s.%d" % (base_oid, idx + 4)
            res_online = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                 "-On", params.get("host", "localhost"), online_oid],
                                 mutates=False)
            
            if res_online.rc != 0:
                idx += 1
                continue
            
            online_val = res_online.stdout.split(" = ")[-1].strip() if " = " in res_online.stdout else ""
            
            # Get other fields
            degree_oid = "%s.%d" % (base_oid, idx + 2)
            unit_oid = "%s.%d" % (base_oid, idx + 11)
            status_oid = "%s.%d" % (base_oid, idx + 3)
            low_crit_oid = "%s.%d" % (base_oid, idx + 9)
            low_warn_oid = "%s.%d" % (base_oid, idx + 8)
            high_warn_oid = "%s.%d" % (base_oid, idx + 6)
            high_crit_oid = "%s.%d" % (base_oid, idx + 7)
            degreeraw_oid = "%s.%d" % (base_oid, idx + 13)
            
            # Adjust for SP2PLUS
            if base_oid == OID_BASE_SP2PLUS:
                degree_oid = "%s.%d" % (base_oid, idx + 2)
                unit_oid = "%s.%d" % (base_oid, idx + 3)
                status_oid = "%s.%d" % (base_oid, idx + 4)
                low_crit_oid = "%s.%d" % (base_oid, idx + 7)
                low_warn_oid = "%s.%d" % (base_oid, idx + 8)
                high_warn_oid = "%s.%d" % (base_oid, idx + 9)
                high_crit_oid = "%s.%d" % (base_oid, idx + 10)
                degreeraw_oid = "%s.%d" % (base_oid, idx + 18)
            
            # Fetch all fields
            degree_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                 "-On", params.get("host", "localhost"), degree_oid],
                                 mutates=False)
            unit_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                               "-On", params.get("host", "localhost"), unit_oid],
                               mutates=False)
            status_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                 "-On", params.get("host", "localhost"), status_oid],
                                 mutates=False)
            low_crit_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                   "-On", params.get("host", "localhost"), low_crit_oid],
                                   mutates=False)
            low_warn_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                   "-On", params.get("host", "localhost"), low_warn_oid],
                                   mutates=False)
            high_warn_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                    "-On", params.get("host", "localhost"), high_warn_oid],
                                    mutates=False)
            high_crit_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                    "-On", params.get("host", "localhost"), high_crit_oid],
                                    mutates=False)
            degreeraw_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                    "-On", params.get("host", "localhost"), degreeraw_oid],
                                    mutates=False)
            
            # Extract values
            degree = degree_res.stdout.split(" = ")[-1].strip() if " = " in degree_res.stdout else ""
            unit = unit_res.stdout.split(" = ")[-1].strip() if " = " in unit_res.stdout else ""
            status = status_res.stdout.split(" = ")[-1].strip() if " = " in status_res.stdout else ""
            low_crit = low_crit_res.stdout.split(" = ")[-1].strip() if " = " in low_crit_res.stdout else ""
            low_warn = low_warn_res.stdout.split(" = ")[-1].strip() if " = " in low_warn_res.stdout else ""
            high_warn = high_warn_res.stdout.split(" = ")[-1].strip() if " = " in high_warn_res.stdout else ""
            high_crit = high_crit_res.stdout.split(" = ")[-1].strip() if " = " in high_crit_res.stdout else ""
            degreeraw = degreeraw_res.stdout.split(" = ")[-1].strip() if " = " in degreeraw_res.stdout else ""
            
            sensor_data = {
                "description": desc,
                "degree": degree,
                "unit": unit,
                "status": status,
                "low_crit": low_crit,
                "low_warn": low_warn,
                "high_warn": high_warn,
                "high_crit": high_crit,
                "degreeraw": degreeraw,
                "online": online_val
            }
            break
        
        idx += 1
    
    # If we didn't find the item
    if sensor_data == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Extract fields
    description = sensor_data["description"]
    degree = sensor_data["degree"]
    unit = sensor_data["unit"]
    status = sensor_data["status"]
    low_crit = sensor_data["low_crit"]
    low_warn = sensor_data["low_warn"]
    high_warn = sensor_data["high_warn"]
    high_crit = sensor_data["high_crit"]
    degreeraw = sensor_data["degreeraw"]
    online = sensor_data["online"]
    
    # Initialize result
    result_state = "OK"
    result_msg = ""
    result_metrics = {}
    details = ""
    
    # Check if online
    if online != "1":
        result_state = "CRIT"
        details = "sensor is offline"
    
    # Check status
    if status in AKCP_SENSOR_LEVEL_STATES:
        state_num, state_name = AKCP_SENSOR_LEVEL_STATES[status]
        if state_num == 2:
            result_state = "CRIT"
        elif state_num == 1:
            if result_state != "CRIT":
                result_state = "WARN"
        if details:
            details += ", "
        details += "State: " + state_name
    
    # Process temperature
    unit_normalized = _normalize_unit(unit)
    
    # Normalize thresholds
    low_c, low_w, high_w, high_c = _normalize_thresholds(low_crit, low_warn, high_warn, high_crit, unit)
    
    # Determine temperature value
    temperature = 0.0
    if degreeraw and degreeraw != "0":
        if degreeraw.isdigit() or (degreeraw.startswith("-") and degreeraw[1:].isdigit()):
            temperature = float(degreeraw) / 10.0
        else:
            temperature = 0.0
    elif degree:
        if degree.isdigit() or (degree.startswith("-") and degree[1:].isdigit()):
            temperature = float(degree)
        else:
            temperature = 0.0
    else:
        result_state = "UNKNOWN"
        details += "Temperature information not found"
        return {
            "changed": False,
            "msg": details,
            "data": {
                "state": result_state,
                "metrics": result_metrics,
                "details": details
            }
        }
    
    # Apply temperature thresholds (from Checkmk default if not specified in params)
    warn = params.get("levels", AKCP_TEMP_CHECK_DEFAULT_PARAMETERS["levels"])[1]
    crit = params.get("levels", AKCP_TEMP_CHECK_DEFAULT_PARAMETERS["levels"])[0]
    
    # Check against high thresholds
    if high_w != None and temperature >= high_w:
        if result_state != "CRIT":
            result_state = "WARN"
    if high_c != None and temperature >= high_c:
        result_state = "CRIT"
    
    # Check against low thresholds
    if low_w != None and temperature <= low_w:
        if result_state != "CRIT":
            result_state = "WARN"
    if low_c != None and temperature <= low_c:
        result_state = "CRIT"
    
    # Build message
    result_msg = "%s: %f %s" % (item, temperature, unit_normalized.upper())
    if details:
        result_msg += " (%s)" % details
    
    # Set metrics
    result_metrics = {"temperature": temperature}
    
    return {
        "changed": False,
        "msg": result_msg,
        "data": {
            "state": result_state,
            "metrics": result_metrics,
            "details": details
        }
    }
