# Constants for sensor types (from Bintec SNMP schema)
SENSOR_TYPE_TEMP = "1"
SENSOR_TYPE_FAN = "2"
SENSOR_TYPE_VOLTAGE = "3"

def main(ctx, params):
    if params.get("_discover"):
        # Discover voltage sensors (type == "3")
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.272.4.17.7.1.1.1"
        
        # Fetch all sensor data via SNMP: oid 2=descr, 3=type, 4=value, 5=unit
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base_oid + ".2", base_oid + ".3", base_oid + ".4", base_oid + ".5"
        ], mutates=False)
        
        # Parse SNMP output: each line has format "OID.index = STRING/INTEGER: value"
        # We'll group values by index (row) from the walk
        # Since snmpwalk returns all requested OIDs interleaved, parse carefully
        
        # Simpler approach: walk each OID separately and align
        descr_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid + ".2"
        ], mutates=False)
        type_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid + ".3"
        ], mutates=False)
        value_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid + ".4"
        ], mutates=False)
        
        # Parse into lists
        def parse_snmpwalk(output):
            items = []
            for line in output.strip().splitlines():
                if not line:
                    continue
                # Format: ".oid.index = type: value"
                parts = line.split(" = ", 1)
                if len(parts) != 2:
                    continue
                oid_part, value_part = parts
                # Extract index from OID: last numeric part after last dot
                # e.g., ".1.3.6.1.4.1.272.4.17.7.1.1.1.2.1" -> index "1"
                oid_components = oid_part.strip().rsplit(".", 1)
                if len(oid_components) != 2:
                    continue
                index = oid_components[1]
                # Extract value
                value = value_part.strip()
                if ": " in value:
                    value = value.split(": ", 1)[1]
                items.append((index, value))
            return items
        
        descrs = parse_snmpwalk(descr_res.stdout)
        types = parse_snmpwalk(type_res.stdout)
        values = parse_snmpwalk(value_res.stdout)
        
        # Build index->sensor mapping
        sensors = {}
        for idx, d in descrs:
            sensors[idx] = {"descr": d}
        for idx, t in types:
            if idx in sensors:
                sensors[idx]["type"] = t
        for idx, v in values:
            if idx in sensors:
                sensors[idx]["value"] = v
        
        # Discover voltage sensors (type == "3")
        discovered = []
        for idx, s in sensors.items():
            if s.get("type") == SENSOR_TYPE_VOLTAGE:
                item_name = s.get("descr", "voltage")
                discovered.append({
                    "item": item_name,
                    "params": {},
                    "metrics": ["voltage"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(discovered),
            "data": {"discovery": discovered}
        }
    
    # Check mode: verify one voltage sensor
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item is required",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.272.4.17.7.1.1.1"
    
    # Get sensor type and value for the specific item
    # We need to find the sensor row index by description
    descr_res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, base_oid + ".2"
    ], mutates=False)
    
    # Parse to find the index for this item
    target_idx = None
    for line in descr_res.stdout.strip().splitlines():
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        oid_components = oid_part.strip().rsplit(".", 1)
        if len(oid_components) != 2:
            continue
        index = oid_components[1]
        # Extract value
        value = value_part.strip()
        if ": " in value:
            value = value.split(": ", 1)[1]
        # Unquote string if needed
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        if value == item:
            target_idx = index
            break
    
    if target_idx == None:
        return {
            "changed": False,
            "msg": "Sensor %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Now fetch type, value for this index
    type_oid = base_oid + ".3." + target_idx
    value_oid = base_oid + ".4." + target_idx
    
    type_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, type_oid
    ], mutates=False)
    value_res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, value_oid
    ], mutates=False)
    
    # Parse type
    sensor_type = None
    for line in type_res.stdout.strip().splitlines():
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        if ": " in value_part:
            sensor_type = value_part.split(": ", 1)[1].strip()
            break
    
    # Parse value
    sensor_value = None
    for line in value_res.stdout.strip().splitlines():
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        if ": " in value_part:
            sensor_value = value_part.split(": ", 1)[1].strip()
            break
    
    if sensor_type != SENSOR_TYPE_VOLTAGE:
        return {
            "changed": False,
            "msg": "Sensor %s is not a voltage sensor (type %s)" % (item, sensor_type),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse voltage value - guard before conversion
    if sensor_value == None or sensor_value == "":
        return {
            "changed": False,
            "msg": "Invalid voltage value for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Check if value is numeric before conversion
    if not sensor_value.replace("-", "").isdigit():
        return {
            "changed": False,
            "msg": "Invalid voltage value for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    raw_value = int(sensor_value)
    voltage = float(raw_value) / 1000.0
    
    return {
        "changed": False,
        "msg": "%s is at %f V" % (item, voltage),
        "data": {
            "state": "OK",
            "metrics": {"voltage": voltage},
            "details": ""
        }
    }
