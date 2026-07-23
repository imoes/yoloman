# Module-level constant: sensor ID to name mapping
CLIMAVENETA_SENSORS = {
    1: "Room",
    3: "Outlet Air 1",
    4: "Outlet Air 2",
    5: "Outlet Air 3",
    6: "Outlet Air 4",
    7: "Intlet Air 1",
    8: "Intlet Air 2",
    9: "Intlet Air 3",
    10: "Intlet Air 4",
    11: "Coil 1 Inlet Water",
    12: "Coil 2 Inlet Water",
    13: "Coil 1 Outlet Water",
    14: "Coil 2 Outlet Water",
    23: "Regulation Valve/Compressor",
    24: "Regulation Fan 1",
    25: "Regulation Fan 2",
    28: "Suction",
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # SNMP parameters with defaults
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        res_ids = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.9839.2.1"
        ], mutates=False)
        
        res_values = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.9839.2.1.2"
        ], mutates=False)
        
        if res_ids.rc != 0 or res_values.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }
        
        # Build value map from second walk
        value_map = {}
        for line in res_values.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            
            oid = parts[0]
            value_str = parts[1]
            if oid.startswith(".1.3.6.1.4.1.9839.2.1."):
                remainder = oid[len(".1.3.6.1.4.1.9839.2.1."):]
                sensor_id_str = remainder.split(".")[0]
                if sensor_id_str.isdigit():
                    sensor_id = int(sensor_id_str)
                    if value_str.isdigit():
                        value_map[sensor_id] = int(value_str)
        
        # Process discovery
        discovery_items = []
        for line in res_ids.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            
            oid = parts[0]
            if not oid.startswith(".1.3.6.1.4.1.9839.2.1."):
                continue
            
            remainder = oid[len(".1.3.6.1.4.1.9839.2.1."):]
            sensor_id_str = remainder.split(".")[0]
            
            if not sensor_id_str.isdigit():
                continue
            
            sensor_id = int(sensor_id_str)
            
            # Check if sensor ID is valid and value is positive
            if sensor_id in CLIMAVENETA_SENSORS and sensor_id in value_map and value_map[sensor_id] > 0:
                discovery_items.append({
                    "item": CLIMAVENETA_SENSORS[sensor_id],
                    "params": {"levels": (28.0, 30.0)},
                    "metrics": ["temp"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode (normal path)
    item = params.get("item", "")
    warn = params.get("levels", (28.0, 30.0))[0] if isinstance(params.get("levels"), (list, tuple)) else params.get("warn", 28.0)
    crit = params.get("levels", (28.0, 30.0))[1] if isinstance(params.get("levels"), (list, tuple)) else params.get("crit", 30.0)
    
    # SNMP parameters
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.9839.2.1.2"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Map item to sensor ID (reverse lookup)
    sensor_id = None
    for sid, sname in CLIMAVENETA_SENSORS.items():
        if sname == item:
            sensor_id = sid
            break
    
    if sensor_id == None:
        return {
            "changed": False,
            "msg": "unknown temperature sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Look for sensor value
    for line in res.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        
        oid = parts[0]
        value_str = parts[1]
        
        # Check if this OID matches our sensor
        prefix = ".1.3.6.1.4.1.9839.2.1.%d" % sensor_id
        if oid.startswith(prefix) and len(oid) > len(prefix) and oid[len(prefix)] == '.':
            if value_str.isdigit():
                value = int(value_str)
                if value > 0:
                    # Convert to temperature (tenths of degree)
                    temp = value / 10.0
                    
                    # Determine state based on thresholds
                    state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
                    
                    return {
                        "changed": False,
                        "msg": "Temperature: %f C" % temp,
                        "data": {
                            "state": state,
                            "metrics": {"temp": temp},
                            "details": ""
                        }
                    }
    
    # Sensor not found or value <= 0
    return {
        "changed": False,
        "msg": "sensor %s not found or invalid value" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
