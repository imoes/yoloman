def main(ctx, params):
    # Constants for SNMP and sensor value mapping
    DIGITAL_VALUE_NAMES = {
        "0": "closed",
        "1": "open",
    }
    
    # Base OIDs for the two supported device families
    OID_BASE_ENVIROMUX = ".1.3.6.1.4.1.3699.1.1.11.1.6.1.1"
    OID_BASE_ENVIROMUX5 = ".1.3.6.1.4.1.3699.1.1.10.1.6.1.1"
    
    # Default SNMP parameters
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    def walk_oids(base_oid):
        # Walk both base OIDs and combine results
        results = []
        for base in [base_oid]:
            res = ctx.run([
                "snmpwalk",
                "-v2c",
                "-c", community,
                "-On", host,
                base
            ], mutates=False)
            if res.rc == 0:
                for line in res.stdout.splitlines():
                    if "=" in line:
                        parts = line.strip().split("=", 1)
                        if len(parts) == 2:
                            oid_part = parts[0].strip()
                            value_part = parts[1].strip()
                            # Extract the OID suffix (last number after the base)
                            suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
                            value_type_value = value_part.split(": ", 1)
                            if len(value_type_value) == 2:
                                value = value_type_value[1].strip()
                                results.append((suffix, value))
        return results
    
    if params.get("_discover"):
        # Discovery mode: gather all digital sensors
        # Walk the base OID for enviromux_digital section
        raw_data = walk_oids(OID_BASE_ENVIROMUX)
        if not raw_data:
            raw_data = walk_oids(OID_BASE_ENVIROMUX5)
        
        items = []
        # Group by index (first part of the OID suffix)
        sensors = {}
        for suffix, value in raw_data:
            parts = suffix.split(".")
            if len(parts) >= 4:
                idx = parts[-1]  # The last part is the index
                oid_type = parts[-2]  # The second to last identifies the OID type
                if idx not in sensors:
                    sensors[idx] = {}
                if oid_type == "1":  # digInputIndex
                    sensors[idx]["index"] = value
                elif oid_type == "3":  # digInputDescription
                    sensors[idx]["description"] = value
                elif oid_type == "7":  # digInputValue
                    sensors[idx]["value"] = DIGITAL_VALUE_NAMES.get(value, "unknown")
                elif oid_type == "9":  # digInputNormalValue
                    sensors[idx]["normal_value"] = DIGITAL_VALUE_NAMES.get(value, "unknown")
        
        # Build discovery items
        discovery = []
        for idx, data in sensors.items():
            # Construct item name from description and index if available
            description = data.get("description", "").strip('"')
            item_name = "%s %s" % (description if description else "sensor", idx)
            discovery.append({
                "item": item_name,
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d digital sensors" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode: examine one specific sensor item
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Extract index from item name (last part after space)
    idx = item.rsplit(" ", 1)[-1] if " " in item else item
    
    # Walk the base OIDs to get all data
    raw_data = walk_oids(OID_BASE_ENVIROMUX)
    if not raw_data:
        raw_data = walk_oids(OID_BASE_ENVIROMUX5)
    
    # Find sensor data matching this item
    sensor_data = {}
    for suffix, value in raw_data:
        parts = suffix.split(".")
        if len(parts) >= 4:
            sensor_idx = parts[-1]
            if sensor_idx == idx:
                oid_type = parts[-2]
                if oid_type == "7":  # digInputValue
                    sensor_data["value"] = DIGITAL_VALUE_NAMES.get(value, "unknown")
                elif oid_type == "9":  # digInputNormalValue
                    sensor_data["normal_value"] = DIGITAL_VALUE_NAMES.get(value, "unknown")
    
    # Check if sensor data exists
    if "value" not in sensor_data:
        return {
            "changed": False,
            "msg": "digital sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Determine state based on sensor values
    value = sensor_data.get("value", "unknown")
    normal_value = sensor_data.get("normal_value", "unknown")
    
    if value == "unknown":
        return {
            "changed": False,
            "msg": "Sensor value is unknown",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    elif value == normal_value:
        return {
            "changed": False,
            "msg": "Sensor Value is normal: " + value,
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }
    else:
        return {
            "changed": False,
            "msg": "Sensor Value is not normal: %s . It should be: %s" % (value, normal_value),
            "data": {"state": "CRIT", "metrics": {}, "details": ""}
        }
