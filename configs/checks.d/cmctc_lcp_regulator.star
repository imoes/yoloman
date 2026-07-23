# Sensor type mapping from Checkmk plugin
_CMCTC_LCP_SENSORS = {
    "4": (None, "access"),
    "12": (None, "humidity"),
    "13": ("normally open", "user"),
    "14": ("normally closed", "user"),
    "23": (None, "flow"),
    "30": (None, "current"),
    "31": (None, "status"),
    "32": (None, "position"),
    "40": ("1", "blower"),
    "41": ("2", "blower"),
    "42": ("3", "blower"),
    "43": ("4", "blower"),
    "44": ("5", "blower"),
    "45": ("6", "blower"),
    "46": ("7", "blower"),
    "47": ("8", "blower"),
    "48": ("Server in 1", "temp"),
    "49": ("Server out 1", "temp"),
    "50": ("Server in 2", "temp"),
    "51": ("Server out 2", "temp"),
    "52": ("Server in 3", "temp"),
    "53": ("Server out 3", "temp"),
    "54": ("Server in 4", "temp"),
    "55": ("Server out 4", "temp"),
    "56": ("Overview Server in", "temp"),
    "57": ("Overview Server out", "temp"),
    "58": ("Water in", "temp"),
    "59": ("Water out", "temp"),
    "60": (None, "flow"),
    "61": (None, "blowergrade"),
    "62": (None, "regulator"),
}

# SNMP base trees for data collection
_TREE_INDICES = ["3", "4", "5", "6"]

# Status mapping: Checkmk status codes
_MAP_SENSOR_STATE = {
    "1": (3, "not available"),
    "2": (2, "lost"),
    "3": (1, "changed"),
    "4": (0, "ok"),
    "5": (2, "off"),
    "6": (0, "on"),
    "7": (1, "warning"),
    "8": (2, "too low"),
    "9": (2, "too high"),
    "10": (2, "error"),
}

# Unit suffix mapping
_MAP_UNIT = {
    "access": "",
    "current": " A",
    "status": "",
    "position": "",
    "temp": " °C",
    "blower": " RPM",
    "blowergrade": "",
    "humidity": "%",
    "flow": " l/min",
    "regulator": "%",
    "user": "",
}


def _is_float(s):
    """Check if string can be parsed as float."""
    s = s.strip()
    if not s:
        return False
    # Handle negative numbers
    if s.startswith("-"):
        s = s[1:]
    # Check if contains exactly one dot
    parts = s.split(".")
    if len(parts) > 2:
        return False
    for p in parts:
        if not p:
            return False
        for c in p:
            if c < "0" or c > "9":
                return False
    return True


def _collect_sensors(ctx):
    """Collect sensor data via SNMP for all trees."""
    all_sensors = {}
    
    for tree in _TREE_INDICES:
        base_oid = ".1.3.6.1.4.1.2606.4.2." + tree
        # Query all relevant OIDs for this tree
        res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", base_oid], mutates=False)
        
        if res.rc != 0:
            continue
        
        # Parse SNMP walk output
        lines = res.stdout.splitlines()
        current_sensor = {}
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
            
            # Format: OID = TYPE: value
            eq_pos = line.find(" = ")
            if eq_pos == -1:
                continue
            
            oid = line[:eq_pos].strip()
            value = line[eq_pos + 3:].strip()
            
            # Remove type prefix (STRING:, INTEGER:, etc.)
            colon_pos = value.find(":")
            if colon_pos >= 0:
                value = value[colon_pos + 1:].strip()
            
            # Extract field index from OID
            # OID format: .1.3.6.1.4.1.2606.4.2.{tree}.5.2.1.{field_index}.{row_index}
            parts = oid.split(".")
            if len(parts) >= 10:
                field_idx_str = parts[-2]
                field_idx = int(field_idx_str) if field_idx_str.isdigit() else 0
                row_idx = parts[-1]
                
                # Determine field type
                if field_idx == 1:
                    current_sensor = {"tree": tree, "index": row_idx}
                elif field_idx == 2:
                    current_sensor["typeid"] = value
                elif field_idx == 4:
                    current_sensor["status"] = value
                elif field_idx == 5:
                    current_sensor["reading"] = value
                elif field_idx == 6:
                    current_sensor["high"] = value
                elif field_idx == 7:
                    current_sensor["low"] = value
                elif field_idx == 8:
                    current_sensor["warn"] = value
                
                # If we have all fields, process the sensor
                if len(current_sensor) >= 7:
                    typeid = current_sensor.get("typeid")
                    if typeid and typeid in _CMCTC_LCP_SENSORS:
                        sensor_spec = _CMCTC_LCP_SENSORS[typeid]
                        item = (sensor_spec[0] + " - " + current_sensor["tree"] + "." + current_sensor["index"]) if sensor_spec[0] else (current_sensor["tree"] + "." + current_sensor["index"])
                        
                        reading_val = current_sensor.get("reading", "0")
                        high_val = current_sensor.get("high", "0")
                        low_val = current_sensor.get("low", "0")
                        warn_val = current_sensor.get("warn", "0")
                        
                        reading = float(reading_val) if _is_float(reading_val) else 0.0
                        high = float(high_val) if _is_float(high_val) else 0.0
                        low = float(low_val) if _is_float(low_val) else 0.0
                        warn = float(warn_val) if _is_float(warn_val) else 0.0
                        
                        sensor = {
                            "status": current_sensor.get("status", "1"),
                            "reading": reading,
                            "high": high,
                            "low": low,
                            "warn": warn,
                            "description": current_sensor.get("description", ""),
                            "type_": sensor_spec[1],
                        }
                        all_sensors[item] = sensor
                    current_sensor = {}
    
    return all_sensors


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        sensors = _collect_sensors(ctx)
        
        # Filter for regulator type only
        regulator_sensors = []
        for item, sensor in sensors.items():
            if sensor["type_"] == "regulator":
                regulator_sensors.append({
                    "item": item,
                    "params": {},  # Checkmk default params are empty dict
                    "metrics": ["regulator"],
                })
        
        return {
            "changed": False,
            "msg": "discovered %d regulators" % len(regulator_sensors),
            "data": {"discovery": regulator_sensors},
        }
    
    # Check mode for specific item
    item = params.get("item", "")
    sensors = _collect_sensors(ctx)
    
    if item not in sensors:
        return {
            "changed": False,
            "msg": "sensor not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    sensor = sensors[item]
    
    # Get sensor info
    unit = _MAP_UNIT.get(sensor["type_"], "")
    infotext = ""
    if sensor["description"]:
        infotext += "[" + sensor["description"] + "] "
    
    # Status mapping
    status_val = sensor["status"]
    state_code = 3
    status_text = "UNKNOWN"
    if status_val in _MAP_SENSOR_STATE:
        state_code, status_text = _MAP_SENSOR_STATE[status_val]
    
    # Checkmk states: 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN
    # Map to our states: "OK", "WARN", "CRIT", "UNKNOWN"
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state = state_map.get(state_code, "UNKNOWN")
    
    # Format output
    reading = sensor["reading"]
    summary = infotext + str(int(reading)) + unit
    
    # Handle levels if provided in params
    extra_info = ""
    extra_state = 0
    if params:
        warn = params.get("warn", 0)
        crit = params.get("crit", 0)
        if crit > 0 or warn > 0:
            if reading >= crit:
                extra_state = 2
            elif reading >= warn:
                extra_state = 1
            
            if extra_state > 0:
                extra_info = " (warn/crit at %d/%d%s)" % (int(warn), int(crit), unit)
    else:
        # Use device thresholds if no explicit params
        if sensor["low"] < sensor["high"]:
            if reading >= sensor["high"] or reading <= sensor["low"]:
                extra_state = 2
                extra_info = " (device lower/upper crit at %d/%d%s)" % (int(sensor["low"]), int(sensor["high"]), unit)
    
    # Final state selection
    final_state = "CRIT" if extra_state == 2 else ("WARN" if extra_state == 1 else state)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": final_state,
            "metrics": {"regulator": reading},
            "details": extra_info,
        },
    }