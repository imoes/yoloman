def main(ctx, params):
    # ===== Module constants (defined at top level) =====
    # SNMP base OID for CMCIII PSM current sensors
    OID_PSM_CURRENT_TABLE = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2.12"
    
    # Metric name for current
    METRIC_NAME = "current"
    
    # ===== Helper: walk SNMP table for PSM current sensors =====
    def walk_psm_current():
        # Use snmpwalk to get the entire PSM current table
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            OID_PSM_CURRENT_TABLE
        ], mutates=False)
        
        if res.rc != 0:
            return {}
        
        # Parse the snmpwalk output: OID = TYPE: value
        sensors = {}
        for line in res.stdout.splitlines():
            if not line or "=" not in line:
                continue
            parts = line.split("=", 1)
            if len(parts) != 2:
                continue
            oid = parts[0].strip()
            value_part = parts[1].strip()
            
            # Extract value after type (e.g., "INTEGER: 123" -> "123")
            if ":" in value_part:
                value = value_part.split(":", 1)[1].strip()
            else:
                value = value_part
            
            # Map OID to sensor index based on sub OID
            # OID structure: .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.12.<index>.<field>
            suffix = oid.replace(OID_PSM_CURRENT_TABLE + ".", "", 1)
            if "." not in suffix:
                continue
            index, field = suffix.split(".", 1)
            
            if index not in sensors:
                sensors[index] = {}
            sensors[index][field] = value
        
        return sensors
    
    # ===== Helper: get item key and current data =====
    def get_current_data():
        sensors = walk_psm_current()
        # Filter for current-specific fields (we need Value, SetPtHighAlarm, SetPtLowAlarm, etc.)
        result = []
        for idx, sensor in sensors.items():
            # Extract required fields; missing fields result in None
            entry = {
                "index": idx,
                "Value": sensor.get("1"),      # Current value
                "SetPtHighAlarm": sensor.get("2"),  # min_current
                "SetPtLowAlarm": sensor.get("3"),   # max_current
                "Unit Type": sensor.get("4"),
                "Serial Number": sensor.get("5"),
                "Mounting Position": sensor.get("6"),
                "DescName": sensor.get("7"),
                "_location_": sensor.get("8", ""),  # location (for description-based items)
                "_index_": sensor.get("9", ""),     # index (for description-based items)
                "Status": sensor.get("10", "OK"),
            }
            # Only include entries that have a current value
            if entry["Value"] != None:
                result.append(entry)
        return result
    
    # ===== Helper: get item name =====
    def get_item_name(sensor, use_sensor_description):
        if use_sensor_description:
            return "{}-{} {}".format(sensor.get("_location_", ""), sensor.get("_index_", ""), sensor.get("DescName", ""))
        return sensor.get("index", "")
    
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        sensors = get_current_data()
        items = []
        for sensor in sensors:
            item = get_item_name(sensor, params.get("use_sensor_description", False))
            items.append({
                "item": item,
                "params": {"_item_key": sensor["index"]},
                "metrics": [METRIC_NAME],
            })
        return {
            "changed": False,
            "msg": "discovered %d current sensors" % len(items),
            "data": {"discovery": items},
        }
    
    # ===== CHECK MODE =====
    # Get item key from params (discovered service uses _item_key)
    item_key = params.get("_item_key", "")
    # If not found via _item_key, try item
    if not item_key and params.get("item"):
        # For compatibility with older services that used the item as the key
        # but we'll treat the item as the index if _item_key is missing
        item_key = params.get("item", "")
    
    # Get current data and find the matching sensor
    all_sensors = get_current_data()
    entry = None
    for sensor in all_sensors:
        if sensor["index"] == item_key:
            entry = sensor
            break
    
    # Item not found
    if entry == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item_key,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Extract values (convert to float/int where possible)
    current = 0.0
    if entry["Value"] != None and entry["Value"].lstrip("-").replace(".", "", 1).isdigit():
        current = float(entry["Value"])
    
    # Extract alarm levels
    min_current = None
    max_current = None
    if entry["SetPtHighAlarm"] != None and entry["SetPtHighAlarm"].lstrip("-").replace(".", "", 1).isdigit():
        min_current = float(entry["SetPtHighAlarm"])
    if entry["SetPtLowAlarm"] != None and entry["SetPtLowAlarm"].lstrip("-").replace(".", "", 1).isdigit():
        max_current = float(entry["SetPtLowAlarm"])
    
    # Determine state from Status field and alarm levels
    state = "OK"
    summary_parts = []
    
    # Check Status
    if entry["Status"] != "OK":
        state = "CRIT"
    
    # Check alarm levels if available
    if min_current != None and max_current != None:
        if current < min_current or current > max_current:
            if state == "OK":
                state = "CRIT"
    
    # Build summary message
    summary_parts.append("Current: %f (%f/%f)" % (
        current, 
        min_current if min_current != None else 0.0, 
        max_current if max_current != None else 0.0
    ))
    
    # Add additional info
    if entry["Unit Type"] != None:
        summary_parts.append("Type: " + entry["Unit Type"])
    if entry["Serial Number"] != None:
        summary_parts.append("Serial: " + entry["Serial Number"])
    if entry["Mounting Position"] != None:
        summary_parts.append("Position: " + entry["Mounting Position"])
    
    msg = ", ".join(summary_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"current": current},
            "details": "",
        },
    }
