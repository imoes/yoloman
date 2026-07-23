# Constants for OID tree
EMC_ISILON_TEMP_BASE = ".1.3.6.1.4.1.12124.2.54.1"
EMC_ISILON_TEMP_OID_NAME = "3"
EMC_ISILON_TEMP_OID_VALUE = "4"

# Default thresholds (from Checkmk defaults)
DEFAULT_TEMP_LEVELS = (28.0, 33.0)
DEFAULT_TEMP_CPU_LEVELS = (75.0, 85.0)

def _isilon_temp_item_name(sensor_name):
    if "CPU Throttle" in sensor_name:
        # Extract CPU number: "Temp Until CPU Throttle (CPU 0)" -> "CPU 0"
        idx = sensor_name.find("(")
        if idx != -1:
            end = sensor_name.find(")", idx)
            if end != -1:
                return sensor_name[idx+1:end]
        return ""
    # Remove leading "Temp " (5 chars): "Temp Front Panel" -> "Front Panel"
    if sensor_name.startswith("Temp "):
        return sensor_name[5:]
    return sensor_name

def _discover_isilon_temp(section, is_cpu):
    result = []
    for entry in section:
        if len(entry) >= 2:
            sensor_name = entry[0]
            item_name = _isilon_temp_item_name(sensor_name)
            if item_name.startswith("CPU") == is_cpu:
                # Determine levels based on item type
                levels = DEFAULT_TEMP_CPU_LEVELS if is_cpu else DEFAULT_TEMP_LEVELS
                result.append({
                    "item": item_name,
                    "params": {
                        "levels": list(levels)
                    },
                    "metrics": ["temp"]
                })
    return result

def _check_temperature(value, params):
    levels = params.get("levels", [28.0, 33.0])
    warn = levels[0] if len(levels) >= 1 else 28.0
    crit = levels[1] if len(levels) >= 2 else 33.0
    
    # Check logic: upper thresholds
    if value >= crit:
        state = "CRIT"
        msg = "CRIT (warn at %s, crit at %s)" % (str(warn), str(crit))
    elif value >= warn:
        state = "WARN"
        msg = "WARN (warn at %s, crit at %s)" % (str(warn), str(crit))
    else:
        state = "OK"
        msg = "OK"
    
    return state, msg

def main(ctx, params):
    if params.get("_discover"):
        # SNMP probe for temperature data
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Walk the temperature section
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            EMC_ISILON_TEMP_BASE
        ], mutates=False)
        
        # Parse snmpwalk output: OID = STRING: value
        section = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Format: .1.3.6.1.4.1.12124.2.54.1.3.1 = STRING: "Temp Until CPU Throttle (CPU 0)"
            #         .1.3.6.1.4.1.12124.2.54.1.4.1 = INTEGER: 30
            # Split into OID and value parts
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            oid_part = line[:eq_idx].strip()
            val_part = line[eq_idx+1:].strip()
            
            # Determine if this is name or value OID
            oid_end = oid_part.rsplit(".", 1)[-1]
            if oid_part.endswith(EMC_ISILON_TEMP_OID_NAME):
                # Name entry: extract sensor name (strip quotes)
                name = val_part
                if name.startswith('"') and name.endswith('"'):
                    name = name[1:-1]
                # Store name with index as key
                section.append((int(oid_end), "name", name))
            elif oid_part.endswith(EMC_ISILON_TEMP_OID_VALUE):
                # Value entry: extract numeric temperature
                if val_part.startswith("INTEGER:"):
                    val_str = val_part[8:].strip()
                elif val_part.startswith("INTEGER: "):
                    val_str = val_part[9:].strip()
                else:
                    continue
                if val_str.isdigit():
                    val = float(val_str)
                    section.append((int(oid_end), "value", val))
            else:
                continue
        
        # Group by index (sensor ID) to pair name and value
        sensors = {}
        for item in section:
            idx = item[0]
            if idx not in sensors:
                sensors[idx] = {}
            if item[1] == "name":
                sensors[idx]["name"] = item[2]
            elif item[1] == "value":
                sensors[idx]["value"] = item[2]
        
        # Build section: list of [name, value] pairs
        final_section = []
        for idx in sorted(sensors.keys()):
            s = sensors[idx]
            if "name" in s and "value" in s:
                final_section.append([s["name"], s["value"]])
        
        # Discover both regular and CPU temperature services
        discovery = []
        discovery.extend(_discover_isilon_temp(final_section, is_cpu=False))
        discovery.extend(_discover_isilon_temp(final_section, is_cpu=True))
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    # Check mode (non-discovery)
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch all sensor data
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        EMC_ISILON_TEMP_BASE
    ], mutates=False)
    
    # Parse into section
    sensors = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        eq_idx = line.find("=")
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx].strip()
        val_part = line[eq_idx+1:].strip()
        
        oid_end = oid_part.rsplit(".", 1)[-1]
        if oid_part.endswith(EMC_ISILON_TEMP_OID_NAME):
            name = val_part
            if name.startswith('"') and name.endswith('"'):
                name = name[1:-1]
            sensors[int(oid_end)] = {"name": name}
        elif oid_part.endswith(EMC_ISILON_TEMP_OID_VALUE):
            if val_part.startswith("INTEGER:"):
                val_str = val_part[8:].strip()
            elif val_part.startswith("INTEGER: "):
                val_str = val_part[9:].strip()
            else:
                continue
            if val_str.isdigit():
                val = float(val_str)
                if int(oid_end) in sensors:
                    sensors[int(oid_end)]["value"] = val
    
    # Build section list
    section = []
    for idx in sorted(sensors.keys()):
        s = sensors[idx]
        if "name" in s and "value" in s:
            section.append([s["name"], s["value"]])
    
    # Find matching item
    found = False
    for sensor_name, value in section:
        if item == _isilon_temp_item_name(sensor_name):
            found = True
            # Get parameters
            is_cpu = item.startswith("CPU")
            levels = params.get("levels", list(DEFAULT_TEMP_CPU_LEVELS if is_cpu else DEFAULT_TEMP_LEVELS))
            warn = levels[0] if len(levels) >= 1 else (28.0 if not is_cpu else 75.0)
            crit = levels[1] if len(levels) >= 2 else (33.0 if not is_cpu else 85.0)
            
            state, msg = _check_temperature(value, {"levels": [warn, crit]})
            
            return {
                "changed": False,
                "msg": "%s, %s: %f°C" % (msg, item, value),
                "data": {
                    "state": state,
                    "metrics": {"temp": value},
                    "details": ""
                }
            }
    
    # Item not found
    return {
        "changed": False,
        "msg": "temperature sensor '%s' not found" % item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": ""
        }
    }