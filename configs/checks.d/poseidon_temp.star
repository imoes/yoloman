# ===== Starlark check: poseidon_temp =====
# Read-only check for Poseidon temperature sensors via SNMP

# Sensor state mapping
SENSOR_STATES = {
    "0": "invalid",
    "1": "normal",
    "2": "alarmstate",
    "3": "alarm",
}

def _parse_value(value_string):
    # Guard instead of try/except
    if value_string == None:
        return None
    # Remove trailing "C" if present
    clean = value_string
    if value_string.endswith("C"):
        clean = value_string[:-1]
    # Check if string is numeric (including decimal point)
    if clean == "":
        return None
    # Allow digits, dot, minus sign only
    for ch in clean:
        if (ch < "0" or ch > "9") and ch != "." and ch != "-":
            return None
    # Parse with built-in float conversion
    try_val = float(clean)  # float() is allowed in Starlark
    return try_val

def _snmp_get_value(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    if res.rc != 0:
        return None
    output = res.stdout.strip()
    # Format: OID = TYPE: value
    idx = output.find(" = ")
    if idx == -1:
        return None
    value_part = output[idx+3:].strip()
    # Handle type prefixes (INTEGER:, STRING:, etc.)
    if value_part.startswith("STRING: "):
        return value_part[8:].strip('"')
    elif value_part.startswith("INTEGER: "):
        return value_part[9:]
    elif value_part.startswith("OID: "):
        return value_part[5:]
    else:
        return value_part

def _discover_sensors(ctx, community, host):
    base_oid = ".1.3.6.1.4.1.21796.3.3.3.1"
    name_oid = base_oid + ".2"
    state_oid = base_oid + ".4"
    value_oid = base_oid + ".5"
    
    # Get all names
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, name_oid], mutates=False)
    if res.rc != 0:
        return []
    
    name_map = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        idx = line.find(" = ")
        if idx == -1:
            continue
        oid_part = line[:idx].strip()
        value_part = line[idx+3:].strip()
        if value_part.startswith("STRING: "):
            value = value_part[8:].strip('"')
        else:
            value = value_part
        # Extract instance from OID: base.2.instance
        if oid_part.startswith(name_oid + "."):
            instance = oid_part[len(name_oid)+1:]
            name_map[instance] = value
    
    # Get states for all instances
    state_map = {}
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, state_oid], mutates=False)
    if res.rc == 0:
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            idx = line.find(" = ")
            if idx == -1:
                continue
            oid_part = line[:idx].strip()
            value_part = line[idx+3:].strip()
            if value_part.startswith("INTEGER: "):
                value = value_part[9:]
            else:
                value = value_part
            if oid_part.startswith(state_oid + "."):
                instance = oid_part[len(state_oid)+1:]
                state_map[instance] = value
    
    # Get values for all instances
    value_map = {}
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, value_oid], mutates=False)
    if res.rc == 0:
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            idx = line.find(" = ")
            if idx == -1:
                continue
            oid_part = line[:idx].strip()
            value_part = line[idx+3:].strip()
            if value_part.startswith("STRING: "):
                value = value_part[8:].strip('"')
            else:
                value = value_part
            if oid_part.startswith(value_oid + "."):
                instance = oid_part[len(value_oid)+1:]
                value_map[instance] = value
    
    # Build items
    items = []
    for instance in name_map:
        name = name_map[instance]
        state = state_map.get(instance)
        value_string = value_map.get(instance)
        items.append({
            "item": name,
            "params": {},
            "metrics": ["temp"],
        })
    
    return items

def main(ctx, params):
    if params.get("_discover") != None:
        community = "public"
        host = "localhost"
        if params.get("community") != None:
            community = params["community"]
        if params.get("host") != None:
            host = params["host"]
        items = _discover_sensors(ctx, community, host)
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(items),
            "data": {"discovery": items},
        }
    
    item = params.get("item", "")
    community = "public"
    host = "localhost"
    if params.get("community") != None:
        community = params["community"]
    if params.get("host") != None:
        host = params["host"]
    
    # Get names and find instance for item
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.21796.3.3.3.1.2"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    name_to_instance = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        idx = line.find(" = ")
        if idx == -1:
            continue
        oid_part = line[:idx].strip()
        value_part = line[idx+3:].strip()
        if value_part.startswith("STRING: "):
            value = value_part[8:].strip('"')
        else:
            value = value_part
        if oid_part.startswith(".1.3.6.1.4.1.21796.3.3.3.1.2."):
            instance_id = oid_part[len(".1.3.6.1.4.1.21796.3.3.3.1.2."):]
            name_to_instance[value] = instance_id
    
    if not item in name_to_instance:
        return {
            "changed": False,
            "msg": "sensor not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    inst = name_to_instance[item]
    # Query state and value for this instance
    state_val = _snmp_get_value(ctx, community, host, ".1.3.6.1.4.1.21796.3.3.3.1.4." + inst)
    value_str = _snmp_get_value(ctx, community, host, ".1.3.6.1.4.1.21796.3.3.3.1.5." + inst)
    
    # Determine state
    status = state_val if state_val != None else ""
    state_txt = SENSOR_STATES.get(status) if (status in SENSOR_STATES) else "unknown"
    mk_status = "OK"
    if status != "1":
        mk_status = "CRIT"
    
    # Process temperature
    temp = _parse_value(value_str) if value_str != None else None
    temp_str = "%f C" % temp if temp != None else "no data"
    
    # Build summary
    summary = "Sensor %s, State %s" % (item, state_txt)
    if temp != None:
        summary += ", Temp %s" % temp_str
    else:
        summary += ", No data"
    
    metrics = {}
    if temp != None:
        metrics["temp"] = temp
    
    # Check levels (defaults are Checkmk defaults for temperature)
    warn = params.get("levels", (25.0, 30.0))
    crit = params.get("levels", (30.0, 35.0))
    if type(warn) == "list":
        warn = warn[1]
    if type(crit) == "list":
        crit = crit[1]
    warn = params.get("levels_upper", warn)
    crit = params.get("levels_upper", crit)
    if type(warn) == "tuple":
        warn = warn[1]
    if type(crit) == "tuple":
        crit = crit[1]
    
    # Grade against upper levels
    if temp != None:
        if temp >= crit:
            mk_status = "CRIT"
        elif temp >= warn:
            if mk_status == "OK":
                mk_status = "WARN"
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": mk_status,
            "metrics": metrics,
            "details": "",
        },
    }