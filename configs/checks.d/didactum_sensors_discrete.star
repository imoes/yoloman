# ===== Starlark translation of checkmk.didactum_sensors_discrete =====

# Module constants: SNMP OIDs and state mapping (must be top-level)
_BASE_OID = ".1.3.6.1.4.1.46501.5.1.1"
_TYPE_OID_BASE = ".4"        # ctlInternalSensorsDiscretType
_NAME_OID_BASE = ".5"        # ctlInternalSensorsDiscretName
_STATE_OID_BASE = ".6"       # ctlInternalSensorsDiscretState
_VALUE_OID_BASE = ".7"       # ctlInternalSensorsDiscretValue

# State mapping: string -> Checkmk state name
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

def _walk_snmp(ctx, host, community):
    # Walk base OID .1.3.6.1.4.1.46501.5.1.1.4, .5, .6 for discrete sensors
    # We use snmpwalk for the base and then parse OIDs ending in 4,5,6
    base = _BASE_OID
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community,
        "-On", host, base + ".4", base + ".5", base + ".6"
    ], mutates=False)
    
    # Parse lines like: .1.3.6.1.4.1.46501.5.1.1.4.101001 = STRING: "dry"
    parsed = []
    for line in res.stdout.splitlines():
        # Expected format: OID = TYPE: VALUE (no quotes in our output)
        # But some snmpwalks use quotes, so strip them
        eq_idx = line.find("=")
        if eq_idx == -1:
            continue
        oid_part = line[:eq_idx].strip()
        value_part = line[eq_idx+1:].strip()
        # Remove quotes if present
        if value_part.startswith('"') and value_part.endswith('"'):
            value_part = value_part[1:-1]
        else:
            value_part = value_part.strip()
        parsed.append((oid_part, value_part))
    return parsed

def _parse_sensors(ctx, host, community):
    # Walk all discrete sensors and build section dict
    raw = _walk_snmp(ctx, host, community)
    
    # Build a dict: {sensor_type: {sensor_name: {"state": ..., "state_readable": ..., "value": ...}}}
    section = {}
    
    # We'll build mappings from OID suffix to type/name/state
    # OIDs are: .base.4.<suffix>, .base.5.<suffix>, .base.6.<suffix>
    type_data = {}
    name_data = {}
    state_data = {}
    
    for oid, val in raw:
        # Extract suffix after .base.4/5/6
        suffix = oid.rsplit(".", 1)[-1]
        base = oid.rsplit(".", 1)[0]
        
        if base.endswith(".4"):
            type_data[suffix] = val.lower()
        elif base.endswith(".5"):
            name_data[suffix] = val
        elif base.endswith(".6"):
            state_data[suffix] = val.lower()
    
    # Now iterate over all suffixes (union of keys)
    all_suffixes = set(type_data.keys()) | set(name_data.keys()) | set(state_data.keys())
    
    for suffix in all_suffixes:
        sensor_type = type_data.get(suffix, "")
        sensor_name = name_data.get(suffix, "")
        state_str = state_data.get(suffix, "unknown")
        
        # Map state string to Checkmk state
        state = _STATE_MAP.get(state_str, "UNKNOWN")
        state_readable = state_str if state_str in _STATE_MAP else "unknown[" + state_str + "]"
        
        # Create sensor dict
        sensor = {
            "state": state,
            "state_readable": state_readable,
        }
        
        # If value OID exists, try to get it (not in walk above, but we can try snmpget if needed)
        # For simplicity, assume no value in this discrete sensor section
        # (the original code only reads type/name/state for discrete sensors)
        
        # Group by type then name
        if sensor_type == "":
            continue
        section.setdefault(sensor_type, {})[sensor_name] = sensor
    
    return section

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        section = _parse_sensors(ctx, host, community)
        
        out = []
        # Discover dry and smoke sensors (per check source)
        for sensor_type in ["dry", "smoke"]:
            sensors = section.get(sensor_type, {})
            for sensor_name, data in sensors.items():
                if data["state_readable"] not in ("off", "not connected"):
                    out.append({"item": sensor_name, "params": {}, "metrics": []})
        
        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(out),
            "data": {"discovery": out},
        }
    
    # Check mode
    item = params.get("item", "")
    section = _parse_sensors(ctx, host, community)
    
    # Search dry and smoke types for this item (check logic)
    for sensor_type in ["dry", "smoke"]:
        sensor = section.get(sensor_type, {}).get(item)
        if sensor != None:
            # Return state with readable status
            return {
                "changed": False,
                "msg": "Status: " + sensor["state_readable"],
                "data": {
                    "state": sensor["state"],
                    "metrics": {},
                    "details": "",
                },
            }
    
    # Not found -> UNKNOWN
    return {
        "changed": False,
        "msg": "sensor not found: " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }
