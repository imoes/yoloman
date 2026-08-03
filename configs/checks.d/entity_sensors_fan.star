def _parse_sensor_value(raw_value, scale_code):
    # Convert ENTITY-SENSOR-MIB entPhySensorScale code to actual value
    # Scale codes per RFC 3440:
    # 1-9: x10^(n-8) for n in 1..9, i.e. 10^-7, 10^-6, ..., 10^0
    # Actually: the scale is an index into a table where:
    # index 1 = 10^-6, 2 = 10^-5, ... 7 = 1 (10^0), ... 9 = 10^(+1)
    # Wait, standard ENTITY-SENSOR-MIB scale table:
    # 1: 10^-6 (micro), 2: 10^-5, 3: 10^-4, 4: 10^-3 (milli), 5: 10^-2,
    # 6: 10^-1, 7: 1 (units), 8: 10^1, 9: 10^2, 10: 10^3 (kilo), ...
    # 14: 10^6 (mega), ...
    scales = {
        1: 0.000001, 2: 0.00001, 3: 0.0001, 4: 0.001, 5: 0.01,
        6: 0.1, 7: 1.0, 8: 10.0, 9: 100.0, 10: 1000.0,
        11: 10000.0, 12: 100000.0, 13: 1000000.0, 14: 10000000.0,
        15: 100000000.0, 16: 1000000000.0, 17: 0.0000001, 18: 0.00000001,
        19: 0.000000001,
    }
    factor = scales.get(scale_code, 1.0)
    return raw_value * factor

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Check if this is a device that has ENTITY-SENSOR-MIB
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Probe: check sysDescr to see if this is a Palo Alto, Cisco ASA, or Arista
        descr_res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Ovqn",
            host, ".1.3.6.1.2.1.1.1.0"
        ], mutates=False)
        
        if descr_res.rc != 0:
            return {"changed": False, "msg": "SNMP not available",
                    "data": {"discovery": []}}
        
        descr = descr_res.stdout.strip().lower()
        is_supported = False
        for prefix in ["palo alto networks", "cisco adaptive security appliance", "arista networks"]:
            if descr.startswith(prefix):
                is_supported = True
                break
        
        if not is_supported:
            return {"changed": False, "msg": "device not supported",
                    "data": {"discovery": []}}
        
        # Fetch entity names from ENTITY-MIB
        entities_res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Ovqn",
            host, ".1.3.6.1.2.1.47.1.1.1.1.7"
        ], mutates=False)
        
        entity_names = {}
        if entities_res.rc == 0:
            for line in entities_res.stdout.splitlines():
                parts = line.split(" ", 1)  # -Oqn format: "OID suffix VALUE"
                if len(parts) == 2:
                    oid = parts[0]
                    name = parts[1].strip().strip('"')
                    # Extract entity index from OID suffix
                    idx = oid[len(".1.3.6.1.2.1.47.1.1.1.1.7") + 1:]
                    if idx:
                        entity_names[idx] = name
        
        # Fetch sensor data from ENTITY-SENSOR-MIB
        # We need entPhySensorType, entPhySensorScale, entPhySensorValue,
        # entPhySensorOperStatus, entPhySensorUnitsDisplay
        sensors = {}
        sensor_base = ".1.3.6.1.2.1.99.1.1.1.1"
        
        sensor_oids = ["2", "3", "4", "5", "6"]  # type, scale, value, operStatus, unitsDisplay
        for col in sensor_oids:
            sensor_res = ctx.run([
                "snmpwalk", "-v2c", "-c", community, "-Ovqn",
                host, sensor_base + "." + col
            ], mutates=False)
            
            if sensor_res.rc == 0:
                for line in sensor_res.stdout.splitlines():
                    parts = line.split(" ", 1)
                    if len(parts) == 2:
                        oid = parts[0]
                        value = parts[1].strip()
                        idx = oid[len(sensor_base + "." + col) + 1:]
                        if idx not in sensors:
                            sensors[idx] = {}
                        sensors[idx][col] = value
        
        # Find fan sensors (type == 10)
        fan_items = []
        for idx, sensor in sensors.items():
            sens_type = sensor.get("2", "")
            if sens_type == "10" and idx in entity_names:
                item = entity_names[idx]
                lower = params.get("lower", [2000, 1000])
                fan_items.append({
                    "item": item,
                    "params": {"lower": lower},
                    "metrics": ["fan"]
                })
        
        return {"changed": False, "msg": "discovered %d fan sensors" % len(fan_items),
                "data": {"discovery": fan_items}}
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # ... read data and apply levels