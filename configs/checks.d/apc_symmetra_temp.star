# module-level constants for SNMP OIDs
_BASE_OID_TEMP = ".1.3.6.1.4.1.318.1.1.10.4.2.3.1"
_OID_TEMP_SENSOR_NAME = "3"
_OID_TEMP_VALUE = "5"

# Default thresholds from Checkmk plugin
_DEFAULT_LEVELS_BATTERY = (50, 60)
_DEFAULT_LEVELS_SENSORS = (25, 30)

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), _BASE_OID_TEMP
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            # Extract OID suffix
            suffix = oid_part.rsplit(".", 1)[-1]
            # Extract value (type:value format)
            if ":" in value_part:
                value = value_part.split(":", 1)[1].strip()
            else:
                value = value_part.strip()
            
            # Only process temperature sensor entries
            if suffix == _OID_TEMP_SENSOR_NAME:
                sensor_name = value.strip('"')
                items.append({
                    "item": sensor_name,
                    "params": {"levels_battery": _DEFAULT_LEVELS_BATTERY, "levels_sensors": _DEFAULT_LEVELS_SENSORS},
                    "metrics": ["temp"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode: process one item
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), _BASE_OID_TEMP
    ], mutates=False)
    
    # Parse SNMP output to find the requested item's temperature
    temp_value = None
    sensor_found = False
    
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        # Extract OID suffix
        suffix = oid_part.rsplit(".", 1)[-1]
        # Extract value (type:value format)
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip()
        else:
            value = value_part.strip()
        
        if suffix == _OID_TEMP_SENSOR_NAME:
            sensor_name = value.strip('"')
            if sensor_name == item:
                sensor_found = True
        elif suffix == _OID_TEMP_VALUE and sensor_found:
            # Found the temperature value - parse safely without try/except
            # Check for integer or float format
            clean_val = value.replace(".", "", 1).lstrip("-")
            if clean_val.isdigit() and value.count(".") <= 1:
                temp_value = float(value)
            else:
                temp_value = None
            break
    
    # Determine thresholds based on item name
    levels_battery = params.get("levels_battery", _DEFAULT_LEVELS_BATTERY)
    levels_sensors = params.get("levels_sensors", _DEFAULT_LEVELS_SENSORS)
    
    if item == "Battery":
        warn, crit = levels_battery[0], levels_battery[1]
    else:
        warn, crit = levels_sensors[0], levels_sensors[1]
    
    # Determine state based on thresholds
    if temp_value == None:
        return {
            "changed": False,
            "msg": "temperature sensor '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    state = "OK"
    msg_parts = ["%s: %f C" % (item, temp_value)]
    
    if temp_value >= crit:
        state = "CRIT"
        msg_parts.append("(crit at %f C)" % crit)
    elif temp_value >= warn:
        state = "WARN"
        msg_parts.append("(warn at %f C)" % warn)
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"temp": temp_value},
            "details": ""
        }
    }
