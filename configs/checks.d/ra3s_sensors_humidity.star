# SNMP base OID for digital sensors (humidity data)
DIGITAL_SENSORS_BASE = ".1.3.6.1.4.1.20916.1.13.1.2.1"

# Sensor type mapping (from detect_sensor_type)
SENSOR_TYPE_HUMIDITY = 6

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: check for digital sensors that are of TEMP_HUMIDITY type
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Walk digital sensors section (OIDs 1-6 per sensor)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, DIGITAL_SENSORS_BASE
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }
        
        # Parse the SNMP output to group by sensor index
        # OID format: .1.3.6.1.4.1.20916.1.13.1.2.1.<sensor_index>.<oid_index>
        sensor_data = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full, value_str = parts
            # Extract sensor index and OID index
            oid_parts = oid_full.strip().split(".")
            if len(oid_parts) < 11:
                continue
            
            # Get sensor index and OID index without try/except
            sensor_idx_str = oid_parts[-2]
            oid_idx_str = oid_parts[-1]
            if not sensor_idx_str.isdigit() or not oid_idx_str.isdigit():
                continue
            sensor_idx = int(sensor_idx_str)
            oid_idx = int(oid_idx_str)
            
            if sensor_idx not in sensor_data:
                sensor_data[sensor_idx] = {}
            sensor_data[sensor_idx][oid_idx] = value_str.strip()
        
        # Detect sensor types and find TEMP_HUMIDITY sensors
        discovery = []
        for sensor_idx, data in sensor_data.items():
            # Collect raw values for detection
            raw_values = []
            for idx in range(1, 7):
                if idx in data:
                    value = data[idx].split(": ", 1)[-1] if ": " in data[idx] else data[idx]
                    raw_values.append(value)
                else:
                    raw_values.append("")
            
            # Count numeric values for sensor type detection
            count = 0
            for v in raw_values:
                if v.replace('.', '').replace('-', '').isdigit():
                    count += 1
            
            if count == SENSOR_TYPE_HUMIDITY:
                # This is a TEMP_HUMIDITY sensor
                discovery.append({
                    "item": "Sensor",
                    "params": {
                        "levels": (70.0, 80.0)
                    },
                    "metrics": ["humidity"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode: one specific item
    item = params.get("item", "")
    if item != "Sensor":
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Get digital sensor data
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, DIGITAL_SENSORS_BASE
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse sensor data for TEMP_HUMIDITY type
    humidity = None
    
    # Build a single sensor entry
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value_str = parts
        oid_parts = oid_full.strip().split(".")
        if len(oid_parts) < 11:
            continue
        
        # Get sensor index and OID index without try/except
        sensor_idx_str = oid_parts[-2]
        oid_idx_str = oid_parts[-1]
        if not sensor_idx_str.isdigit() or not oid_idx_str.isdigit():
            continue
        sensor_idx = int(sensor_idx_str)
        oid_idx = int(oid_idx_str)
        
        if oid_idx == 3:  # humidity value (3rd OID, 1-based indexing)
            val = value_str.split(": ", 1)[-1] if ": " in value_str else value_str
            # Check if this looks like a humidity value
            val_clean = val.replace('.', '').replace('-', '')
            if val_clean.isdigit() or (val.count('.') == 1 and val_clean.isdigit()):
                humidity = float(val) / 100.0
    
    # Verify it's actually a humidity sensor by checking sensor type via count logic
    # (re-run parsing to detect sensor type properly)
    sensor_data = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value_str = parts
        oid_parts = oid_full.strip().split(".")
        if len(oid_parts) < 11:
            continue
        
        # Get sensor index and OID index without try/except
        sensor_idx_str = oid_parts[-2]
        oid_idx_str = oid_parts[-1]
        if not sensor_idx_str.isdigit() or not oid_idx_str.isdigit():
            continue
        sensor_idx = int(sensor_idx_str)
        oid_idx = int(oid_idx_str)
        
        if sensor_idx not in sensor_data:
            sensor_data[sensor_idx] = {}
        sensor_data[sensor_idx][oid_idx] = value_str.strip()
    
    # Detect sensor type for first sensor
    raw_values = []
    for idx in range(1, 7):
        if 1 in sensor_data and idx in sensor_data[1]:
            value = sensor_data[1][idx].split(": ", 1)[-1] if ": " in sensor_data[1][idx] else sensor_data[1][idx]
            raw_values.append(value)
        else:
            raw_values.append("")
    
    count = 0
    for v in raw_values:
        if v.replace('.', '').replace('-', '').isdigit():
            count += 1
    
    # If it's not a humidity sensor, return UNKNOWN
    if count != SENSOR_TYPE_HUMIDITY:
        return {
            "changed": False,
            "msg": "sensor is not a humidity sensor",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if humidity == None:
        return {
            "changed": False,
            "msg": "humidity value not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get thresholds
    levels = params.get("levels", (70.0, 80.0))
    warn = levels[0] if isinstance(levels, list) else levels
    crit = levels[1] if isinstance(levels, list) else levels
    
    # Determine state
    state = "CRIT" if humidity >= crit else ("WARN" if humidity >= warn else "OK")
    
    return {
        "changed": False,
        "msg": "Humidity: %f %%" % humidity,
        "data": {
            "state": state,
            "metrics": {"humidity": humidity},
            "details": ""
        }
    }