# Map: fru_state string -> (state_readable, state_enum_for_verdict)
_MAP_FRU_STATE = {
    "1": ("unknown", "UNKNOWN"),
    "2": ("empty", "CRIT"),
    "3": ("present", "WARN"),
    "4": ("ready", "OK"),
    "5": ("announce online", "OK"),
    "6": ("online", "OK"),
    "7": ("anounce offline", "CRIT"),
    "8": ("offline", "CRIT"),
    "9": ("diagnostic", "WARN"),
    "10": ("standby", "WARN"),
}

# Fan FRU type codes (strings) that this check monitors
_FAN_FRU_TYPES = ("13",)


def _discover_juniper_fru(section, fru_types):
    out = []
    for fru_name, fru_data in section.items():
        if fru_data.get("fru_type") in fru_types and fru_data.get("fru_state") != "2":
            out.append({"item": fru_name, "params": {}, "metrics": []})
    return out


def _parse_snmpwalk(res):
    mapping = {}
    lines = res.stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        parts = line.split(" = ")
        if len(parts) < 2:
            i += 1
            continue
        oid = parts[0].strip()
        value_part = parts[1].strip()
        # Extract last OID component as index
        idx = oid.rsplit(".", 1)[-1]
        if value_part.startswith("STRING: "):
            mapping[idx] = value_part[8:].strip().strip('"')
        elif value_part.startswith("INTEGER: "):
            val_str = value_part[9:].strip()
            mapping[idx] = int(val_str) if val_str.isdigit() else val_str
        else:
            mapping[idx] = value_part
        i += 1
    return mapping


def _build_section(ctx, community, host):
    # Run snmpwalk commands
    res_name = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.2636.13.1.1.1.1.1"],
        mutates=False
    )
    res_type = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.2636.13.1.3.1.1.2"],
        mutates=False
    )
    res_state = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.4.1.2636.13.1.1.1.1.2"],
        mutates=False
    )
    
    # Parse results
    names = _parse_snmpwalk(res_name)
    types = _parse_snmpwalk(res_type)
    states = _parse_snmpwalk(res_state)
    
    # Build section dict
    section = {}
    for idx in names.keys():
        if idx in types and idx in states:
            fru_type = str(types[idx]) if type(types[idx]) == "int" else types[idx]
            fru_state = str(states[idx]) if type(states[idx]) == "int" else states[idx]
            section[names[idx]] = {"fru_type": fru_type, "fru_state": fru_state}
    
    return section


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        section = _build_section(ctx, community, host)
        discovery = _discover_juniper_fru(section, _FAN_FRU_TYPES)
        return {"changed": False, "msg": "discovered %d fans" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE: single item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    section = _build_section(ctx, community, host)
    if not item in section:
        return {"changed": False, "msg": "fan not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fru_state_str = section[item].get("fru_state", "1")
    # Look up in map; default to unknown
    state_tuple = _MAP_FRU_STATE.get(fru_state_str, ("unknown", "UNKNOWN"))
    state_readable, state_enum = state_tuple

    # Map state_enum to Checkmk state strings
    state_map = {
        "UNKNOWN": "UNKNOWN",
        "OK": "OK",
        "WARN": "WARN",
        "CRIT": "CRIT"
    }
    state_str = state_map.get(state_enum, "UNKNOWN")

    return {
        "changed": False,
        "msg": "Operational status: " + state_readable,
        "data": {
            "state": state_str,
            "metrics": {},
            "details": ""
        }
    }