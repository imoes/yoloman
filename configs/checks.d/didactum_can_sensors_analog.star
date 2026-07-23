# Module: didactum_can_sensors_analog (Starlark check for temperature, humidity, voltage)
# Note: This is a translated Checkmk check. All logic is read-only and uses SNMP.

# Constants for OID paths and sensor types
BASE_OID = ".1.3.6.1.4.1.46501.6.2.1"

# State mapping from SNMP status text to Checkmk states
STATE_MAP = {
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

def _parse_snmp_output(ctx, community, host):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID], mutates=False)
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    
    # Parse SNMP output into structured data
    # OID format: base.section.index -> e.g., .1.3.6.1.4.1.46501.6.2.1.4.201007
    # Fields: 4=name, 5=state, 6=value, 7=levels_upper, 10=levels_lower, 11-13=extra
    sensors = {}  # {index: {field_num: value}}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value_raw = parts[1].strip()
        
        if not oid_full.startswith(BASE_OID):
            continue
        
        suffix = oid_full[len(BASE_OID):]
        if not suffix.startswith("."):
            continue
        
        suffix_parts = suffix[1:].split(".")
        if len(suffix_parts) < 2:
            continue
        
        field_num = suffix_parts[0]
        index = suffix_parts[1]
        
        if not field_num.isdigit():
            continue
        
        # Extract value (remove quotes if present)
        value = value_raw
        if len(value_raw) >= 2 and value_raw[0] == "\"" and value_raw[len(value_raw) - 1] == "\"":
            value = value_raw[1:len(value_raw) - 1]
        
        if index not in sensors:
            sensors[index] = {}
        sensors[index][field_num] = value
    
    return sensors

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    sensors = _parse_snmp_output(ctx, community, host)
    
    # DISCOVERY MODE
    if params.get("_discover"):
        # Build section: {sensor_type: {sensor_name: sensor_data}}
        section = {}
        for index, fields in sensors.items():
            # Get required fields
            if not fields.get("5") or not fields.get("6"):
                continue
            
            name = fields.get("5")
            state = fields.get("6")
            value_str = fields.get("7", "")
            ty = fields.get("4", "")
            
            # Infer type from name if not provided
            if not ty:
                name_lower = name.lower()
                if name_lower.find("temp") != -1:
                    ty = "temperature"
                elif name_lower.find("humid") != -1:
                    ty = "humidity"
                elif name_lower.find("volt") != -1:
                    ty = "voltage"
                else:
                    continue
            
            state_readable = state
            sensor_state = STATE_MAP.get(state, "UNKNOWN")
            
            # Parse value
            value = 0
            if value_str.isdigit():
                value = int(value_str)
            else:
                value = 0
            
            # Get levels if available (fields 10,11,12,13)
            levels_upper = None
            levels_lower = None
            if fields.get("10") and fields.get("11") and fields.get("12") and fields.get("13"):
                warn_lower = 0
                crit_lower = 0
                warn = 0
                crit = 0
                
                if fields.get("10").isdigit():
                    warn_lower = int(fields.get("10"))
                if fields.get("11").isdigit():
                    crit_lower = int(fields.get("11"))
                if fields.get("12").isdigit():
                    warn = int(fields.get("12"))
                if fields.get("13").isdigit():
                    crit = int(fields.get("13"))
                
                levels_upper = [warn, crit]
                levels_lower = [warn_lower, crit_lower]
            
            sensor = {
                "state": sensor_state,
                "state_readable": state_readable,
                "value": value,
            }
            if levels_upper:
                sensor["levels"] = levels_upper
            if levels_lower:
                sensor["levels_lower"] = levels_lower
            
            if not section.get(ty):
                section[ty] = {}
            section[ty][name] = sensor
        
        # Discover temperature sensors
        out = []
        for sensor_name, attrs in section.get("temperature", {}).items():
            if attrs["state_readable"] != "off" and attrs["state_readable"] != "not connected":
                out.append({
                    "item": sensor_name,
                    "params": {"levels": [70, 80]},
                    "metrics": ["temperature"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out},
        }
    
    # CHECK MODE for temperature
    item = params.get("item", "")
    
    # Check if item exists in section
    data = None
    if section.get("temperature") and section["temperature"].get(item):
        data = section["temperature"][item]
    
    if not data:
        return {
            "changed": False,
            "msg": "no such sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Apply thresholds: read warn/crit from params
    # Default values from temperature ruleset
    warn = 70
    crit = 80
    if params.get("levels"):
        warn = params["levels"][0]
        crit = params["levels"][1]
    
    # Use device-specific levels if available
    if data.get("levels"):
        warn = data["levels"][0]
        crit = data["levels"][1]
    
    # Get lower levels if available
    warn_lower = None
    crit_lower = None
    if data.get("levels_lower"):
        warn_lower = data["levels_lower"][0]
        crit_lower = data["levels_lower"][1]
    
    # Calculate state
    value = data["value"]
    state = "OK"
    
    # Check upper levels
    if isinstance(value, int) or isinstance(value, float):
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    
    # Check lower levels
    if warn_lower != None and (isinstance(value, int) or isinstance(value, float)):
        if value <= crit_lower:
            state = "CRIT"
        elif value <= warn_lower:
            state = "WARN"
    
    # Check device status
    sensor_state = data["state"]
    if sensor_state == "CRIT":
        state = "CRIT"
    elif sensor_state == "WARN" and state == "OK":
        state = "WARN"
    
    # Format message
    msg_parts = []
    msg_parts.append("Temperature: %f" % value)
    if data.get("levels"):
        msg_parts.append("(warn at %f, crit at %f)" % (data["levels"][0], data["levels"][1]))
    else:
        msg_parts.append("(warn at %f, crit at %f)" % (warn, crit))
    msg_parts.append("Status: " + data["state_readable"])
    
    return {
        "changed": False,
        "msg": " ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"temperature": value},
            "details": "",
        },
    }
