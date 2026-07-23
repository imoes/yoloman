# ===== Starlark translation: checkmk.didactum_can_sensors_analog_humidity =====

# Mapping from SNMP status strings to Checkmk states
_STATE_MAP = {
    "alarm": "CRIT",
    "high alarm": "CRIT",
    "low alarm": "CRIT",
    "warning": "WARN",
    "high warning": "WARN",
    "low warning": "WARN",
    "normal": "OK",
    "not connected": "UNKNOWN",
    "on": "OK",
    "off": "UNKNOWN",
}

def _is_valid_number(s):
    """Check if string represents a valid number (int or float)."""
    if s == "":
        return False
    # Handle negative numbers
    stripped = s
    if s.startswith("-"):
        stripped = s[1:]
    # Must have at most one dot
    if stripped.count(".") > 1:
        return False
    # All remaining characters must be digits or exactly one dot
    for c in stripped:
        if c != "." and c not in "0123456789":
            return False
    return True

def _parse_section(ctx):
    """Gather and parse the analog sensor data via SNMP."""
    # Base OID for the Didactum CAN sensors analog section
    base_oid = ".1.3.6.1.4.1.46501.6.2.1"
    # We'll use snmpwalk on base_oid.4 and then parse each line
    community = ctx.facts().get("snmp_community", "public")
    host = ctx.facts().get("snmp_host", "localhost")
    
    # Walk the full tree
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    
    lines = res.stdout.splitlines()
    
    # Build maps: sensor_id -> value for each OID type
    name_map = {}
    state_map = {}
    value_map = {}
    crit_lower_map = {}
    warn_lower_map = {}
    warn_map = {}
    crit_map = {}
    
    for line in lines:
        line = line.strip()
        if not line or "=" not in line:
            continue
        # Split OID and value
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_str = parts[0].strip()
        value_str = parts[1].strip()
        
        # Strip quotes from value
        if value_str.startswith('"') and value_str.endswith('"'):
            value_str = value_str[1:-1]
        
        # Extract suffix: base_oid.X.suffix
        if oid_str.startswith(base_oid + "."):
            suffix = oid_str[len(base_oid) + 1:]  # after 'base_oid.'
            idx = suffix.find(".")
            if idx == -1:
                continue
            oid_type = suffix[:idx]
            sensor_id = suffix[idx+1:]
            
            if oid_type == "4":
                name_map[sensor_id] = value_str
            elif oid_type == "5":
                state_map[sensor_id] = value_str
            elif oid_type == "6":
                value_map[sensor_id] = value_str
            elif oid_type == "10":
                crit_lower_map[sensor_id] = value_str
            elif oid_type == "11":
                warn_lower_map[sensor_id] = value_str
            elif oid_type == "12":
                warn_map[sensor_id] = value_str
            elif oid_type == "13":
                crit_map[sensor_id] = value_str
    
    # Build section dict: section[type][name] = sensor_data
    section = {}
    for sensor_id in name_map:
        name = name_map[sensor_id]
        if sensor_id not in state_map or sensor_id not in value_map:
            continue
        
        status = state_map[sensor_id]
        value_str = value_map[sensor_id]
        
        # Determine state
        state = _STATE_MAP.get(status, "UNKNOWN")
        
        # Parse value
        value = None
        if _is_valid_number(value_str):
            value = float(value_str)
        
        sensor_data = {
            "state": state,
            "state_readable": status,
            "value": value,
        }
        
        # Add levels if available
        levels_upper = None
        levels_lower = None
        
        if sensor_id in warn_map and sensor_id in crit_map:
            if _is_valid_number(warn_map[sensor_id]) and _is_valid_number(crit_map[sensor_id]):
                levels_upper = [float(warn_map[sensor_id]), float(crit_map[sensor_id])]
                sensor_data["levels"] = levels_upper
        
        if sensor_id in warn_lower_map and sensor_id in crit_lower_map:
            if _is_valid_number(warn_lower_map[sensor_id]) and _is_valid_number(crit_lower_map[sensor_id]):
                levels_lower = [float(warn_lower_map[sensor_id]), float(crit_lower_map[sensor_id])]
                sensor_data["levels_lower"] = levels_lower
        
        # Insert into section under "humidity"
        section.setdefault("humidity", {})[name] = sensor_data
    
    return section

def _check_humidity(value, params):
    """Implement humidity check logic: warn/crit thresholds for upper and lower bounds."""
    state = "OK"
    details = []
    
    # Upper levels: levels -> [warn, crit]
    levels_upper = params.get("levels", None)
    if levels_upper != None and len(levels_upper) >= 2:
        upper_warn = float(levels_upper[0])
        upper_crit = float(levels_upper[1])
        if value >= upper_crit:
            state = "CRIT"
            details.append(">= %f%% (crit)" % upper_crit)
        elif value >= upper_warn:
            if state != "CRIT":
                state = "WARN"
            details.append(">= %f%% (warn)" % upper_warn)
    
    # Lower levels: levels_lower -> [warn, crit]
    levels_lower = params.get("levels_lower", None)
    if levels_lower != None and len(levels_lower) >= 2:
        lower_warn = float(levels_lower[0])
        lower_crit = float(levels_lower[1])
        if value <= lower_crit:
            state = "CRIT"
            details.append("<= %f%% (crit)" % lower_crit)
        elif value <= lower_warn:
            if state != "CRIT":
                state = "WARN"
            details.append("<= %f%% (warn)" % lower_warn)
    
    return state, ", ".join(details) if details else "OK"

def main(ctx, params):
    if params.get("_discover"):
        section = _parse_section(ctx)
        # Discovery: yield one item per humidity sensor, skipping 'off'/'not connected'
        items = []
        for name, data in section.get("humidity", {}).items():
            if data.get("state_readable", "") not in ("off", "not connected"):
                # Suggest default params — Checkmk default for humidity is no thresholds
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": ["humidity"],
                })
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items},
        }
    
    # Check mode: get item from params
    item = params.get("item", "")
    section = _parse_section(ctx)
    
    # Look up item in humidity section
    sensor = section.get("humidity", {}).get(item)
    
    # If not found, return UNKNOWN
    if sensor == None:
        return {
            "changed": False,
            "msg": "sensor '%s' not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    value = sensor.get("value")
    if value == None:
        return {
            "changed": False,
            "msg": "sensor '%s' has no valid value" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Check type and convert
    if type(value) != "int" and type(value) != "float":
        return {
            "changed": False,
            "msg": "sensor '%s' has invalid value" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    value = float(value)
    
    # Determine base state from sensor status
    state = sensor.get("state", "UNKNOWN")
    
    # Apply thresholds if present (Checkmk default is no thresholds)
    # Use params to override thresholds
    state, details = _check_humidity(value, params)
    
    return {
        "changed": False,
        "msg": "Humidity: %f %%" % value,
        "data": {
            "state": state,
            "metrics": {"humidity": value},
            "details": details,
        },
    }
