MAP_MODULE_TYPES = {
    "0": "vacant",
    "8": "U8, keypad",
    "9": "U9, card module (proximity)",
    "10": "U10, phone module (modem)",
    "11": "U11/U32, up to 8 handles / single point latches",
    "12": "U12/U33, up to 2 handles / single point latches",
    "13": "U13, 4 sensors and 4 relays",
    "14": "U14, communication module",
    "15": "fultifunction module M15",
    "16": "fultifunction module M16",
}

MAP_ACTIVATION_STATES = {
    "-": ("OK", "vacant"),
    "?": ("OK", "detect modus"),
    "x": ("OK", "excluded"),
    "e": ("CRIT", "error"),
    "c": ("CRIT", "collision detected"),
    "w": ("WARN", "wait for dynamic address"),
    "P": ("WARN", "polling"),
    "i": ("OK", "inactive"),
    "t": ("CRIT", "timeout"),
    "T": ("CRIT", "timeout alarm"),
    "A": ("CRIT", "alarm active"),
    "L": ("OK", "alarm latched"),
    "#": ("OK", "OK"),
}

_BASE_OID = "1.3.6.1.4.1.13595.2.1.3.3.1"

def _snmp_val(raw):
    v = raw.split(": ", 1)[1].strip() if ": " in raw else raw.strip()
    if len(v) >= 2 and v.startswith('"') and v.endswith('"'):
        v = v[1:-1]
    return v

def _parse_walk(stdout):
    result = {}
    prefix = _BASE_OID + "."
    for line in stdout.splitlines():
        if " = " not in line:
            continue
        oid_part, val_part = line.split(" = ", 1)
        oid = oid_part.strip()
        if oid.startswith("."):
            oid = oid[1:]
        if not oid.startswith(prefix):
            continue
        result[oid[len(prefix):]] = _snmp_val(val_part)
    return result

def _build_components(walk):
    components = {}
    for suffix, val in walk.items():
        parts = suffix.split(".")
        if len(parts) != 3:
            continue
        col = parts[0]
        mo_index = parts[1]
        co_index = parts[2]
        if col != "3" or co_index != "0":
            continue
        mod_info = walk.get("5." + mo_index + ".0", "")
        if mo_index == "0":
            name = "Master " + mod_info.split(",")[0]
        else:
            name = "Perip " + mo_index + " " + mod_info
        components[name.strip()] = {
            "activation": val,
            "type": MAP_MODULE_TYPES.get("0", "vacant"),
        }
    return components

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, "." + _BASE_OID],
        mutates=False,
    )

    if res.rc != 0 or not res.stdout.strip():
        if params.get("_discover"):
            return {"changed": False, "msg": "SNMP unavailable", "data": {"discovery": []}}
        detail = res.stderr.strip() if res.stderr else "no data"
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + detail,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": detail},
        }

    walk = _parse_walk(res.stdout)
    components = _build_components(walk)

    if params.get("_discover"):
        items = [
            {"item": name, "params": {}, "metrics": []}
            for name, attrs in components.items()
            if attrs.get("activation") != "i"
        ]
        return {
            "changed": False,
            "msg": "discovered %d modules" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    if item not in components:
        return {
            "changed": False,
            "msg": "module not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    attrs = components[item]
    activation = attrs.get("activation", "")
    state_info = MAP_ACTIVATION_STATES.get(activation)
    if state_info == None:
        return {
            "changed": False,
            "msg": "unknown activation state: " + activation,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = state_info[0]
    state_readable = state_info[1]
    module_type = attrs.get("type", "unknown")

    return {
        "changed": False,
        "msg": "Activation status: %s, Type: %s" % (state_readable, module_type),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }