# Checkmk cmciii check - Rittal CMCIII device state monitoring via SNMP
# Translated to read-only Starlark

# SNMP OIDs
SYS_OBJECT_ID = ".1.3.6.1.2.1.1.2.0"
RITTAL_ENTERPRISE = ".1.3.6.1.4.1.2606.7"
DEVICE_BASE = ".1.3.6.1.4.1.2606.7.4.1.2.1"
VAR_BASE = ".1.3.6.1.4.1.2606.7.4.2.2.1"

# Device table column OIDs
COL_DEV_NAME = DEVICE_BASE + ".2"
COL_DEV_ALIAS = DEVICE_BASE + ".3"
COL_DEV_STATUS = DEVICE_BASE + ".6"

# Variable table column OIDs  
COL_VAR_NAME = VAR_BASE + ".3"
COL_VAR_TYPE = VAR_BASE + ".4"
COL_VAR_UNIT = VAR_BASE + ".5"
COL_VAR_SCALE = VAR_BASE + ".7"
COL_VAR_VAL_STR = VAR_BASE + ".10"
COL_VAR_VAL_INT = VAR_BASE + ".11"

# Status mapping (from MAP_STATES)
MAP_STATES = {
    "1": ("UNKNOWN", "not available"),
    "2": ("OK", "OK"),
    "3": ("WARN", "detect"),
    "4": ("CRIT", "lost"),
    "5": ("WARN", "changed"),
    "6": ("CRIT", "error"),
}

def _snmp_walk(ctx, community, host, oid):
    """Walk an SNMP column, returning dict of {index: value}."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return {}
    result = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        full_oid, value = parts[0], parts[1]
        idx = full_oid[len(oid):]
        # idx starts with "."; strip it
        if idx.startswith("."):
            idx = idx[1:]
        result[idx] = value
    return result

def _snmp_get(ctx, community, host, oid):
    """Get a single SNMP scalar value."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _detect_cmciii(ctx, params):
    """Check if this is a Rittal CMCIII device."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sysoid = _snmp_get(ctx, community, host, SYS_OBJECT_ID)
    if not sysoid:
        return False
    return RITTAL_ENTERPRISE in sysoid

def _parse_devices(ctx, params):
    """Parse the device table into states dict."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    names = _snmp_walk(ctx, community, host, COL_DEV_NAME)
    aliases = _snmp_walk(ctx, community, host, COL_DEV_ALIAS)
    statuses = _snmp_walk(ctx, community, host, COL_DEV_STATUS)
    
    # Collect all indices
    all_indices = list(names.keys()) + list(aliases.keys()) + list(statuses.keys())
    # Deduplicate
    seen = set()
    indices = []
    for idx in all_indices:
        if idx not in seen:
            seen.add(idx)
            indices.append(idx)
    
    devices = {}
    states = {}
    for num, idx in enumerate(indices, start=1):
        name = names.get(idx, "")
        alias = aliases.get(idx, "")
        status = statuses.get(idx, "1")  # default to "1" (not available) if missing
        
        # Parse device id from endoid - the index IS the endoid
        endoid = idx
        
        # Reproduce parse_devices_and_states logic
        dev_name = alias.replace(" ", "_")
        if not dev_name:
            dev_name = name + "-" + str(num)
        
        if dev_name in states:
            dev_name = alias + " " + endoid
        
        devices.setdefault(endoid, dev_name)
        
        if dev_name in states and states[dev_name]["_location_"] != endoid:
            dev_name += " %s" % endoid
        
        states.setdefault(dev_name, {"status": status, "_location_": endoid})
    
    return devices, states

def main(ctx, params):
    if not _detect_cmciii(ctx, params):
        return {
            "changed": False,
            "msg": "no Rittal CMCIII device detected",
            "data": {"discovery": [], "host_labels": {}},
        }
    
    if params.get("_discover"):
        devices, states = _parse_devices(ctx, params)
        discovery = []
        use_desc = params.get("discovery_params", {}).get("use_sensor_description", False)
        for id_, entry in states.items():
            item = id_
            if use_desc:
                item = "%s %s" % (entry["_location_"], id_)
            discovery.append({
                "item": item,
                "params": {"_item_key": id_},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d devices" % len(discovery),
            "data": {"discovery": discovery},
        }
    
    # Check mode
    item = params.get("item", "")
    devices, states = _parse_devices(ctx, params)
    
    # get_sensor logic: use _item_key if present, else use item
    check_params = params.get("check_params", {})
    item_key = check_params.get("_item_key") if check_params else None
    if item_key:
        entry = states.get(item_key)
    else:
        entry = states.get(item)
    
    if not entry:
        return {
            "changed": False,
            "msg": "no sensor entry found for item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    status = entry.get("status", "1")
    state_info = MAP_STATES.get(status)
    if state_info:
        state, state_readable = state_info
    else:
        state = "UNKNOWN"
        state_readable = "unknown"
    
    return {
        "changed": False,
        "msg": "Status: %s" % state_readable,
        "data": {"state": state, "metrics": {}, "details": ""},
    }