def main(ctx, params):
    # SNMP constants
    base_oid = ".1.3.6.1.3.94.1.8.1"
    oid_name = "3"
    oid_status = "4"
    oid_message = "6"
    oid_type = "7"
    oid_characteristic = "8"
    
    # Status map
    status_map = [
        "undefined",  # 0
        "unknown",    # 1
        "other",      # 2
        "ok",         # 3
        "warning",    # 4
        "failed",     # 5
    ]
    
    def _status_from_sensor(sensor_status):
        if sensor_status == 3:
            return "OK"
        if sensor_status == 4:
            return "WARN"
        if sensor_status == 5:
            return "CRIT"
        return "UNKNOWN"
    
    def _clean_sensor_id(sensor_id):
        return sensor_id.replace("16.0.0.192.221.48.", "").replace(".0.0.0.0.0.0.0.0", "")
    
    # Discovery mode
    if params.get("_discover"):
        snmp_res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), base_oid + "." + oid_type
        ], mutates=False)
        
        items = []
        for line in snmp_res.stdout.splitlines():
            if len(line.strip()) == 0:
                continue
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            full_oid = parts[0].strip()
            oid_value = parts[1].strip()
            
            # Extract value
            value = ""
            if oid_value.startswith("STRING:"):
                value = oid_value[7:].strip().strip('"')
            elif oid_value.startswith("INTEGER:") or oid_value.startswith("Gauge32:"):
                value = oid_value.split(":")[1].strip()
            else:
                continue
            
            # Check type is 5 (power supply)
            if value == "5":
                # Extract sensor ID from OID
                index_part = full_oid[len(base_oid + "."):]
                idx_parts = index_part.split(".")
                if len(idx_parts) >= 1:
                    sensor_id = idx_parts[-1]
                    if len(sensor_id) > 0 and sensor_id != "0":
                        cleaned_id = _clean_sensor_id(sensor_id)
                        items.append({"item": cleaned_id, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d PSUs" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item not specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Fetch all required fields for qlogic_sanbox section
    snmp_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
        params.get("host", "localhost"), base_oid
    ], mutates=False)
    
    name_map = {}
    status_map_data = {}
    message_map = {}
    type_map = {}
    
    for line in snmp_res.stdout.splitlines():
        if len(line.strip()) == 0:
            continue
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        full_oid = parts[0].strip()
        oid_value = parts[1].strip()
        
        # Extract value
        value = ""
        if oid_value.startswith("STRING:"):
            value = oid_value[7:].strip().strip('"')
        elif oid_value.startswith("INTEGER:") or oid_value.startswith("Gauge32:"):
            value = oid_value.split(":")[1].strip()
        else:
            continue
        
        # Parse OID index
        index_part = full_oid[len(base_oid + "."):]
        idx_parts = index_part.split(".")
        if len(idx_parts) >= 6:
            sensor_id = idx_parts[-1]
            field_idx = idx_parts[-2]
            
            # Store based on field index
            if field_idx == oid_name and len(sensor_id) > 0:
                name_map[sensor_id] = value
            elif field_idx == oid_status and len(sensor_id) > 0:
                status_map_data[sensor_id] = value
            elif field_idx == oid_message and len(sensor_id) > 0:
                message_map[sensor_id] = value
            elif field_idx == oid_type and len(sensor_id) > 0:
                type_map[sensor_id] = value
    
    # Iterate over type_map to find matching power supply
    for sensor_id in type_map:
        if type_map[sensor_id] == "5":
            cleaned_id = _clean_sensor_id(sensor_id)
            if cleaned_id == item:
                status_raw = status_map_data.get(sensor_id, "-1")
                sensor_status = -1
                if status_raw.isdigit() or (len(status_raw) > 0 and status_raw[0] == "-" and status_raw[1:].isdigit()):
                    sensor_status = int(status_raw)
                
                sensor_message = message_map.get(sensor_id, "")
                if sensor_status < 0 or sensor_status >= len(status_map):
                    sensor_status_descr = str(sensor_status)
                else:
                    sensor_status_descr = status_map[sensor_status]
                
                state = _status_from_sensor(sensor_status)
                return {
                    "changed": False,
                    "msg": "Power Supply %s reports status %s" % (item, sensor_status_descr),
                    "data": {
                        "state": state,
                        "metrics": {},
                        "details": "Sensor %s reports status %s" % (item, sensor_status_descr),
                    }
                }
    
    return {"changed": False, "msg": "No sensor " + item + " found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}