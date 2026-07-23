# Module: quantum_storage_status
# Translation of Checkmk check: checkmk.quantum_storage_status
# Read-only Starlark check module for yolo-man agent

_QUANTUM_DEVICE_STATE = {
    "1": "Unavailable",
    "2": "Available",
    "3": "Online",
    "4": "Offline",
    "5": "Going online",
    "6": "State not available",
}

_DEFAULT_MAP_STATES = {
    "unavailable": 2,
    "available": 0,
    "online": 0,
    "offline": 2,
    "going online": 1,
    "state not available": 3,
}

_STATE_TO_OK_WARN_CRIT_UNKNOWN = {
    0: "OK",
    1: "WARN",
    2: "CRIT",
    3: "UNKNOWN",
}

def _get_snmp_value_by_oid(ctx, host, community, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return None
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return None
    # First line format: ".1.3.6.1.4.1.2036.2.1.1.4.0 = STRING: "value"
    first_line = lines[0]
    # Extract value after " = "
    eq_idx = first_line.find(" = ")
    if eq_idx == -1:
        return None
    value_part = first_line[eq_idx + 3:].strip()
    # Strip type prefix like "STRING: " or "INTEGER: "
    colon_idx = value_part.find(": ")
    if colon_idx != -1:
        value_part = value_part[colon_idx + 2:].strip()
    # Remove surrounding quotes if present
    if value_part.startswith('"') and value_part.endswith('"'):
        value_part = value_part[1:-1]
    return value_part

def _get_snmp_section(ctx, host, community):
    manufacturer = _get_snmp_value_by_oid(ctx, host, community, ".1.3.6.1.4.1.2036.2.1.1.4.0")
    product = _get_snmp_value_by_oid(ctx, host, community, ".1.3.6.1.4.1.2036.2.1.1.5.0")
    revision = _get_snmp_value_by_oid(ctx, host, community, ".1.3.6.1.4.1.2036.2.1.1.6.0")
    state = _get_snmp_value_by_oid(ctx, host, community, ".1.3.6.1.4.1.2036.2.1.1.7.0")
    serial = _get_snmp_value_by_oid(ctx, host, community, ".1.3.6.1.4.1.2036.2.1.1.12.0")
    return {
        "manufacturer": manufacturer if manufacturer != None else "",
        "product": product if product != None else "",
        "revision": revision if revision != None else "",
        "state": state if state != None else "",
        "serial": serial if serial != None else "",
    }

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        section = _get_snmp_section(ctx, host, community)
        # Check if device is present (section.state is not empty and valid OID detected)
        if section["state"] == "":
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"map_states": _DEFAULT_MAP_STATES},
                        "metrics": [],
                    }
                ]
            },
        }
    
    # Check mode
    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "no such item",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    section = _get_snmp_section(ctx, host, community)
    
    # If no data, return UNKNOWN
    if section["state"] == "":
        return {
            "changed": False,
            "msg": "device info unavailable",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    state_txt = _QUANTUM_DEVICE_STATE.get(section["state"], "Unknown [%s]" % section["state"])
    
    # Map states logic
    map_states = params.get("map_states", _DEFAULT_MAP_STATES)
    state_code = map_states.get(state_txt.lower(), 3)  # default to UNKNOWN
    state_name = _STATE_TO_OK_WARN_CRIT_UNKNOWN.get(state_code, "UNKNOWN")
    
    return {
        "changed": False,
        "msg": state_txt,
        "data": {
            "state": state_name,
            "metrics": {},
            "details": "Manufacturer: %s, Product: %s, Serial: %s" % (
                section["manufacturer"],
                section["product"],
                section["serial"],
            ),
        },
    }