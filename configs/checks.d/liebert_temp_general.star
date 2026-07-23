# ===== Starlark check module: liebert_temp_general =====
# Read-only: never mutates; discovers and reports fluid temperatures from Liebert units

# OID base for the liebert_temp_general SNMP section
_LIEBERT_TEMP_BASE = ".1.3.6.1.4.1.476.1.42.3.9.20.1"

def _temperature_to_celsius(value, unit):
    if value == None:
        return None
    if unit == None:
        return None
    # Attempt to parse as float using string methods
    if type(value) == "int" or type(value) == "float":
        v = float(value)
    else:
        if not (value.strip().find(".") >= 0 or value.strip().isdigit()):
            return None
        v = float(value)
    u = unit.replace("deg ", "").lower()
    if u == "c" or u == "%":
        return v
    elif u == "f":
        return (v - 32) * (5.0 / 9.0)
    elif u == "k":
        return v - 273.15
    else:
        return None

def _snmp_parse_lines(lines):
    parsed = []
    for line in lines:
        if line == "":
            continue
        eq_pos = line.find("=")
        if eq_pos < 0:
            continue
        oid_part = line[:eq_pos].strip()
        rest = line[eq_pos + 1:].strip()
        colon_pos = rest.find(":")
        if colon_pos < 0:
            continue
        type_val = rest[:colon_pos].strip()
        val_part = rest[colon_pos + 1:].strip()
        oid_tokens = oid_part.split(".")
        index = ""
        for t in oid_tokens:
            if t.isdigit():
                index = t
        parsed.append((oid_part, type_val, val_part, index))
    return parsed

def _build_section(parsed_triples):
    sections = {}
    for entry in parsed_triples:
        oid = entry[0]
        type_val = entry[1]
        val = entry[2]
        idx = entry[3]
        if idx == "":
            continue
        if not idx in sections:
            sections[idx] = {"name": None, "value": None, "unit": None}
        if oid.startswith(_LIEBERT_TEMP_BASE + ".10.1.2.2."):
            sections[idx]["name"] = val.strip()
        elif oid.startswith(_LIEBERT_TEMP_BASE + ".20.1.2.2."):
            sections[idx]["value"] = val
        elif oid.startswith(_LIEBERT_TEMP_BASE + ".30.1.2.2."):
            sections[idx]["unit"] = val.strip()
        elif oid.startswith(_LIEBERT_TEMP_BASE + ".10.1.2.1."):
            sections[idx]["name"] = val.strip()
        elif oid.startswith(_LIEBERT_TEMP_BASE + ".20.1.2.1."):
            sections[idx]["value"] = val
        elif oid.startswith(_LIEBERT_TEMP_BASE + ".30.1.2.1."):
            sections[idx]["unit"] = val.strip()
    result = {}
    for idx in sections:
        data = sections[idx]
        name = data["name"]
        if name == None or name == "":
            continue
        name = name.strip()
        if name == "":
            continue
        value = data["value"]
        unit = data["unit"]
        if value == None or value == "" or unit == None or unit == "":
            continue
        celsius = _temperature_to_celsius(value, unit)
        if celsius == None:
            continue
        result[name] = (celsius, unit)
    return result

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            _LIEBERT_TEMP_BASE
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }
        lines = res.stdout.splitlines()
        parsed = _snmp_parse_lines(lines)
        section = _build_section(parsed)
        discovery = []
        for item in section:
            discovery.append({
                "item": item,
                "params": {},
                "metrics": ["temperature"]
            })
        return {
            "changed": False,
            "msg": "discovered %d fluid temperatures" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        _LIEBERT_TEMP_BASE
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    lines = res.stdout.splitlines()
    parsed = _snmp_parse_lines(lines)
    section = _build_section(parsed)
    if not item in section:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    tuple_entry = section[item]
    celsius = tuple_entry[0]
    unit = tuple_entry[1]
    warn = params.get("levels_upper", None)
    if warn == None:
        warn_warn = None
        warn_crit = None
    else:
        if type(warn) == "list" and len(warn) == 2:
            warn_warn = warn[0]
            warn_crit = warn[1]
        else:
            warn_warn = None
            warn_crit = None
    if params.get("warn") != None:
        warn_warn = params.get("warn")
    if params.get("crit") != None:
        warn_crit = params.get("crit")
    state = "OK"
    if warn_warn != None and celsius >= warn_warn:
        state = "WARN"
    if warn_crit != None and celsius >= warn_crit:
        state = "CRIT"
    details = "Temperature: %f C" % celsius
    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": {"temperature": celsius},
            "details": details
        }
    }