# === module: kentix_amp_sensors_humidity.star ===
# Translate Checkmk check: checkmk.kentix_amp_sensors_humidity
# Read-only Starlark check for humidity sensors via SNMP

# OID base for Kentix devices (from DETECT_KENTIX)
KENTIX_OID_BASE = ".1.3.6.1.2.1.1.2.0"
KENTIX_OID_VALUE = ".1.3.6.1.4.1.332.11.6"

# SNMP OIDs for sensor data (from kentix_amp_sensors SNMPTree)
# Base .1.3.6.1.4.1.37954.1, then the single fetch for section
SNMP_BASE = ".1.3.6.1.4.1.37954.1"
SENSOR_TREE_BASE = ".1.3.6.1.4.1.37954.1.2.7"

# Per-sensor OID offsets
# 1: sensor name
# 2: temperature (INTEGER 0..1000)
# 3: humidity (INTEGER 0..1000)
# 4: dew point (INTEGER 0..1000)
# 5: carbon monoxide (INTEGER -100..100, percent)
# 6: motion (INTEGER 0..100)
# 7: digital in 1 (leakage) (INTEGER 0..1)
# 8: digital in 2 (INTEGER 0..1)
# 9: digital out (INTEGER 0..1)
# 10: comError (INTEGER 0..1)
# We need: humidity (offset 3)

def _discover_sensors(ctx, community, host):
    # Walk the entire sensor tree base to discover all sensor names
    base_oid = SENSOR_TREE_BASE + ".1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return []
    
    sensors = []
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        # Parse: .1.3.6.1.4.1.37954.1.2.7.1.N = STRING: "sensor_name"
        # Extract sensor name and ensure it's valid
        parts = stripped.split(" = ")
        if len(parts) < 2:
            continue
        oid_str = parts[0].strip()
        value_part = parts[1].strip()
        # Extract sensor index from OID (last number after last dot)
        if not oid_str.startswith(SENSOR_TREE_BASE + ".1."):
            continue
        # Extract sensor index
        oid_tail = oid_str[len(SENSOR_TREE_BASE + ".1."):]
        if oid_tail == "":
            continue
        # Get sensor name
        # Value format: STRING: "name" or STRING: name (remove quotes)
        sensor_name = value_part
        if sensor_name.startswith("STRING: "):
            sensor_name = sensor_name[8:]
        # Remove surrounding quotes if present
        if sensor_name.startswith('"') and sensor_name.endswith('"'):
            sensor_name = sensor_name[1:-1]
        if sensor_name == "":
            continue
        sensors.append(sensor_name)
    
    return sensors

def _get_humidity(ctx, community, host, item):
    # Find the sensor index for this item by walking OID 1 (sensor names)
    base_oid = SENSOR_TREE_BASE + ".1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return None
    
    sensor_index = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        parts = stripped.split(" = ")
        if len(parts) < 2:
            continue
        oid_str = parts[0].strip()
        value_part = parts[1].strip()
        # Parse: .1.3.6.1.4.1.37954.1.2.7.1.N = STRING: "sensor_name"
        if not oid_str.startswith(SENSOR_TREE_BASE + ".1."):
            continue
        oid_tail = oid_str[len(SENSOR_TREE_BASE + ".1."):]
        if oid_tail == "":
            continue
        # Get sensor name
        sensor_name = value_part
        if sensor_name.startswith("STRING: "):
            sensor_name = sensor_name[8:]
        if sensor_name.startswith('"') and sensor_name.endswith('"'):
            sensor_name = sensor_name[1:-1]
        
        if sensor_name == item:
            sensor_index = oid_tail
            break
    
    if sensor_index == None:
        return None
    
    # Now fetch humidity: SENSOR_TREE_BASE + ".3." + sensor_index
    humidity_oid = SENSOR_TREE_BASE + ".3." + sensor_index
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, humidity_oid], mutates=False)
    if res.rc != 0 or res.stdout.strip() == "":
        return None
    
    # Parse: .1.3.6.1.4.1.37954.1.2.7.3.1 = INTEGER: 474
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        parts = stripped.split(" = ")
        if len(parts) < 2:
            continue
        value_part = parts[1].strip()
        # Extract integer value
        if value_part.startswith("INTEGER: "):
            val_str = value_part[9:]
        elif value_part.startswith("INTEGER:"):
            val_str = value_part[8:]
        else:
            continue
        val_str = val_str.strip()
        if not val_str.isdigit():
            continue
        return float(val_str) / 10.0
    
    return None

def main(ctx, params):
    # Determine SNMP parameters (fallback defaults)
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Discover mode
    if params.get("_discover"):
        sensors = _discover_sensors(ctx, community, host)
        items = []
        for sensor in sensors:
            items.append({"item": sensor, "params": {}, "metrics": ["humidity"]})
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    
    # Get humidity value
    humidity = _get_humidity(ctx, community, host, item)
    if humidity == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Apply thresholds (default levels from Checkmk's humidity check)
    # Checkmk humidity check defaults: levels=(60.0, 80.0) (warn, crit upper)
    warn = params.get("levels", (60.0, 80.0))
    if type(warn) == "list":
        warn = tuple(warn)
    if type(warn) != "tuple" or len(warn) < 2:
        warn = (60.0, 80.0)
    
    warn_val = warn[0]
    crit_val = warn[1]
    
    # Determine state: upper levels only (humidity can't exceed 100%)
    # OK if < warn, WARN if >= warn and < crit, CRIT if >= crit
    if humidity >= crit_val:
        state = "CRIT"
    elif humidity >= warn_val:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "Humidity: %f%%" % humidity
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": ""
        }
    }