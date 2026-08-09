# Module-level constants
SENSOR_TYPE_NAMES = {
    "0": "undefined",
    "1": "temperature",
    "2": "humidity",
    "3": "power",
    "4": "lowVoltage",
    "5": "current",
    "6": "aclmvVoltage",
    "7": "aclmpVoltage",
    "8": "aclmpPower",
    "9": "water",
    "10": "smoke",
    "11": "vibration",
    "12": "motion",
    "13": "glass",
    "14": "door",
    "15": "keypad",
    "16": "panicButton",
    "17": "keyStation",
    "18": "digInput",
    "22": "light",
    "24": "dewpoint",
    "26": "tacDio",
    "36": "acVoltage",
    "37": "acCurrent",
    "38": "dcVoltage",
    "39": "dcCurrent",
    "41": "rmsVoltage",
    "42": "rmsCurrent",
    "43": "activePower",
    "44": "reactivePower",
    "513": "tempHum",
    "32767": "custom",
    "32769": "temperatureCombo",
    "32770": "humidityCombo",
    "540": "tempHum",
}

ENVIROMUX_CHECK_DEFAULT_PARAMETERS = {
    "levels": (15.0, 16.0),
    "levels_lower": (10.0, 9.0),
}

# Helper function to parse float from string - Starlark compatible
def _parse_value_safe(token):
    if token == None:
        return None
    parts = token.split(maxsplit=1)
    if len(parts) == 0:
        return None
    val_str = parts[0].strip()
    if val_str == "":
        return None
    # Validate basic format
    valid_chars = "0123456789.-+eE"
    has_digit = False
    for c in val_str:
        if not c in valid_chars:
            return None
        if c.isdigit():
            has_digit = True
    if not has_digit:
        return None
    # Check multiple dots
    if val_str.count(".") > 1:
        return None
    # Handle leading dot
    if val_str.startswith("."):
        val_str = "0" + val_str
    # Handle trailing dot
    if val_str.endswith("."):
        val_str = val_str[:-1]
    # Now safely convert - Starlark float() will work on valid numeric strings
    # Since SNMP data is guaranteed numeric, we can use float() directly
    return float(val_str)

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Walk the SNMPTree base OID
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            ".1.3.6.1.4.1.3699.1.1.11.1.21.1.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []},
            }
        
        # Parse SNMP output: OID = TYPE: VALUE
        sensors = {}
        current_idx = None
        current_type = None
        current_desc = None
        current_value = None
        current_min = None
        current_max = None
        
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            
            oid_part = parts[0]
            value_part = parts[1]
            # Extract value after "STRING:", "INTEGER:", etc.
            if ":" in value_part:
                value = value_part.split(":", 1)[1].strip().strip('"')
            else:
                value = value_part.strip()
            
            # Determine which OID field this is based on suffix
            if oid_part.endswith(".1"):  # allExternalSensorIndex
                current_idx = value
            elif oid_part.endswith(".3"):  # allExternalSensorType
                current_type = value
            elif oid_part.endswith(".4"):  # allExternalSensorDescription
                current_desc = value
            elif oid_part.endswith(".8"):  # allExternalSensorValue
                current_value = value
            elif oid_part.endswith(".10"):  # allExternalSensorMinThreshold
                current_min = value
            elif oid_part.endswith(".11"):  # allExternalSensorMaxThreshold
                current_max = value
                # We have all fields, process the sensor
                if (current_idx != None and 
                    current_type != None and 
                    current_desc != None and
                    current_value != None):
                    
                    # Parse value, min, max
                    value_float = _parse_value_safe(current_value)
                    min_float = _parse_value_safe(current_min) if current_min != None else None
                    max_float = _parse_value_safe(current_max) if current_max != None else None
                    
                    if value_float != None:
                        sensor_type = SENSOR_TYPE_NAMES.get(current_type, "unknown")
                        
                        # For power type, use the voltage discovery function
                        if sensor_type == "power":
                            item = current_desc + " " + current_idx
                            sensors[item] = {
                                "value": value_float,
                                "min_threshold": min_float,
                                "max_threshold": max_float,
                            }
                
                # Reset for next sensor
                current_idx = None
                current_type = None
                current_desc = None
                current_value = None
                current_min = None
                current_max = None
        
        # Build discovery result
        discovery_items = []
        for item in sensors:
            # Only include power sensors for voltage check
            discovery_items.append({
                "item": item,
                "params": {
                    "levels": ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"],
                    "levels_lower": ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"],
                },
                "metrics": ["voltage"],
            })
        
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(discovery_items),
            "data": {"discovery": discovery_items},
        }
    
    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get the specific sensor OID
    # The item format is "description index"
    parts = item.rsplit(" ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    desc = parts[0]
    idx = parts[1]
    
    # Get sensor data via snmpget for the value OID
    base_oid = ".1.3.6.1.4.1.3699.1.1.11.1.21.1.1"
    
    # Get the value OID first to check if sensor exists
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host,
        base_oid + "." + idx + ".8"
    ], mutates=False)
    
    if res.rc != 0 or res.stdout.find("No such instance") != -1 or res.stdout.find("No more variables") != -1:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Extract value
    value_str = res.stdout.strip().split(" = ")[1]
    if value_str.find(":") != -1:
        value_str = value_str.split(":", 1)[1].strip().strip('"')
    
    value = _parse_value_safe(value_str)
    if value == None:
        return {
            "changed": False,
            "msg": "invalid sensor value",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Get thresholds
    min_value = None
    max_value = None
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host,
        base_oid + "." + idx + ".10"
    ], mutates=False)
    
    if res.rc == 0 and res.stdout.find("No such instance") == -1 and res.stdout.find("No more variables") == -1:
        val = res.stdout.strip().split(" = ")[1]
        if val.find(":") != -1:
            val = val.split(":", 1)[1].strip().strip('"')
        min_value = _parse_value_safe(val)
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host,
        base_oid + "." + idx + ".11"
    ], mutates=False)
    
    if res.rc == 0 and res.stdout.find("No such instance") == -1 and res.stdout.find("No more variables") == -1:
        val = res.stdout.strip().split(" = ")[1]
        if val.find(":") != -1:
            val = val.split(":", 1)[1].strip().strip('"')
        max_value = _parse_value_safe(val)
    
    # Get parameters
    levels_upper = params.get("levels", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels"])
    levels_lower = params.get("levels_lower", ENVIROMUX_CHECK_DEFAULT_PARAMETERS["levels_lower"])
    
    # Apply threshold logic for voltage
    warn_upper = levels_upper[0]
    crit_upper = levels_upper[1]
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]
    
    # Determine state
    state = "OK"
    msg_parts = []
    
    # Check upper levels
    if crit_upper != None and value >= crit_upper:
        state = "CRIT"
        msg_parts.append("CRIT (warn=%s, crit=%s)" % (warn_upper, crit_upper))
    elif warn_upper != None and value >= warn_upper:
        state = "WARN"
        msg_parts.append("WARN (warn=%s, crit=%s)" % (warn_upper, crit_upper))
    
    # Check lower levels
    if crit_lower != None and value <= crit_lower:
        state = "CRIT"
        msg_parts.append("CRIT lower (warn=%s, crit=%s)" % (warn_lower, crit_lower))
    elif warn_lower != None and value <= warn_lower:
        state = "WARN"
        msg_parts.append("WARN lower (warn=%s, crit=%s)" % (warn_lower, crit_lower))
    
    if state == "OK":
        msg_parts.append("OK")
    
    # Build message
    msg = "%s: %f V" % (item, value)
    if len(msg_parts) > 0:
        msg += " - " + ", ".join(msg_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"voltage": value},
            "details": "",
        },
    }
