# ===== Starlark check module: hp_procurve_sensors =====
# Sensor monitoring for HP ProCurve devices via SNMP

_STATUS_MAP = {
    "1": ("UNKNOWN", "unknown"),
    "2": ("CRIT", "bad"),
    "3": ("WARN", "warning"),
    "4": ("OK", "good"),
    "5": ("WARN", "notPresent"),
}

_SENSOR_TYPE_SUFFIX_MAP = {
    "11.2.3.7.8.3.1": "PSU",
    "11.2.3.7.8.3.2": "FAN",
    "11.2.3.7.8.3.3": "Temp",
    "11.2.3.7.8.3.4": "FutureSlot",
}

def _sensor_type(type_input):
    for suffix, name in _SENSOR_TYPE_SUFFIX_MAP.items():
        if type_input.endswith(suffix):
            return name
    return ""

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Fetch all sensor data
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            ".1.3.6.1.4.1.11.2.14.11.1.2.6.1"
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        
        # Parse lines like: .1.3.6.1.4.1.11.2.14.11.1.2.6.1.1.1 = INTEGER: 1
        # Split into key-value pairs by = and extract sensor data
        lines = res.stdout.splitlines()
        sensor_data = []
        
        # We need to group the 4 OID extensions: .1 (id), .2 (type), .4 (status), .7 (description)
        # Build lookup by base OID index
        sensors = {}
        for line in lines:
            line = line.strip()
            if not line or "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value = parts[1].strip()
            # Remove leading type prefix (e.g., "INTEGER: ", "STRING: ")
            if ": " in value:
                value = value.split(": ", 1)[1].strip()
                # Remove quotes from strings
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
            
            # Extract base and suffix
            base_oid = ".1.3.6.1.4.1.11.2.14.11.1.2.6.1."
            if not oid.startswith(base_oid):
                continue
            suffix = oid[len(base_oid):]
            
            # Split suffix to get index and field
            if "." not in suffix:
                continue
            index_part = suffix.rsplit(".", 1)[0]
            field = suffix.rsplit(".", 1)[1]
            
            if index_part not in sensors:
                sensors[index_part] = {}
            
            if field == "1":
                sensors[index_part]["id"] = value
            elif field == "2":
                sensors[index_part]["type"] = value
            elif field == "4":
                sensors[index_part]["status"] = value
            elif field == "7":
                sensors[index_part]["description"] = value
        
        # Build discovery items
        out = []
        for idx, sensor in sensors.items():
            status = sensor.get("status", "5")
            status_name = _STATUS_MAP.get(status, ("UNKNOWN", "unknown"))[1]
            if status_name != "notPresent":
                item = sensor.get("id", "")
                if item:
                    out.append({
                        "item": item,
                        "params": {},
                        "metrics": []
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Fetch all sensor data (same as discovery)
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host,
        ".1.3.6.1.4.1.11.2.14.11.1.2.6.1"
    ], mutates=False)
    if res.rc != 0:
        fail("snmpwalk failed: " + res.stderr)
    
    # Parse lines into sensor data
    lines = res.stdout.splitlines()
    sensors = {}
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()
        if ": " in value:
            value = value.split(": ", 1)[1].strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
        
        base_oid = ".1.3.6.1.4.1.11.2.14.11.1.2.6.1."
        if not oid.startswith(base_oid):
            continue
        suffix = oid[len(base_oid):]
        if "." not in suffix:
            continue
        index_part = suffix.rsplit(".", 1)[0]
        field = suffix.rsplit(".", 1)[1]
        
        if index_part not in sensors:
            sensors[index_part] = {}
        
        if field == "1":
            sensors[index_part]["id"] = value
        elif field == "2":
            sensors[index_part]["type"] = value
        elif field == "4":
            sensors[index_part]["status"] = value
        elif field == "7":
            sensors[index_part]["description"] = value
    
    # Find matching sensor
    for idx, sensor in sensors.items():
        sensor_item = sensor.get("id", "")
        if sensor_item == item:
            status = sensor.get("status", "1")
            status_tuple = _STATUS_MAP.get(status, ("UNKNOWN", "unknown"))
            state = status_tuple[0]
            status_readable = status_tuple[1]
            sensor_type_name = _sensor_type(sensor.get("type", ""))
            description = sensor.get("description", "")
            msg = "Condition of %s \"%s\" is %s" % (sensor_type_name, description, status_readable)
            return {
                "changed": False,
                "msg": msg,
                "data": {
                    "state": state,
                    "metrics": {},
                    "details": ""
                }
            }
    
    # Item not found
    return {
        "changed": False,
        "msg": "item not found in snmp data",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }