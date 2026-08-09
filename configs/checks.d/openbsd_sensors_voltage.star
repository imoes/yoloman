# openbsd_sensors_voltage — translated from Checkmk checkmk.openbsd_sensors_voltage

_OPENBSD_MAP_TYPE = {
    "0": "temp",
    "1": "fan",
    "2": "voltage",
    "9": "indicator",
    "13": "drive",
    "21": "powersupply",
}

_OPENBSD_MAP_STATE = {
    "0": "UNKNOWN",
    "1": "OK",
    "2": "WARN",
    "3": "CRIT",
}

def _safe_float(v):
    if v == None or v == "":
        return 0
    s = str(v)
    sign = 1
    i = 0
    if s.startswith("-"):
        sign = -1
        i = 1
    elif s.startswith("+"):
        i = 1
    num = 0
    frac = 0
    fdiv = 1
    seen_dot = False
    ok = False
    while i < len(s):
        c = s[i]
        if c == "." and not seen_dot:
            seen_dot = True
            ok = True
        elif c >= "0" and c <= "9":
            ok = True
            d = ord(c) - 48
            if seen_dot:
                fdiv = fdiv * 10
                frac = frac + d
            else:
                num = num * 10 + d
        else:
            break
        i = i + 1
    if not ok:
        return v
    return sign * (num + float(frac) / float(fdiv))

def _strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1]
    return s

def _parse_snmp_table(stdout, base_oid):
    result = {}
    if not stdout:
        return result
    base_len = len(base_oid)
    for line in stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        raw = line[sp + 1:]
        if oid.startswith(base_oid + "."):
            idx = oid[base_len + 1:]
            result[idx] = _strip_quotes(raw)
    return result

def _build_section(rows):
    section = {}
    used = set()
    for descr, sensortype, value, unit, state in rows:
        if sensortype not in _OPENBSD_MAP_TYPE:
            continue
        if sensortype == "0" and value == "-273.15":
            continue
        if sensortype in ["1", "2"]:
            fv = _safe_float(value)
            if type(fv) == "float" and fv == 0:
                continue
        item_name = descr
        idx = 0
        while item_name in used:
            item_name = "%s/%d" % (descr, idx)
            idx = idx + 1
        used.add(item_name)
        section[item_name] = {
            "state": _OPENBSD_MAP_STATE.get(state, "UNKNOWN"),
            "value": _safe_float(value),
            "unit": unit,
            "type": _OPENBSD_MAP_TYPE[sensortype],
        }
    return section

def _discover_voltage(section):
    items = []
    for key, values in section.items():
        if values.get("type") == "voltage":
            items.append({"item": key, "params": {"levels": (0, 0)}, "metrics": ["voltage"]})
    return items

def _num(v):
    if type(v) == "int":
        return v
    if type(v) == "float":
        return v
    return 0

def _fetch_table(ctx, host, community, base, col):
    oid = base + "." + col
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return {}
    return _parse_snmp_table(res.stdout, oid)

def _fetch_scalar(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return _strip_quotes(res.stdout)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.30155.2.1.2.1"

    if params.get("_discover"):
        probe = _fetch_scalar(ctx, host, community, ".1.3.6.1.4.1.30155.2.1.1.0")
        if probe == None or probe == "" or probe.find("No Such") != -1:
            return {"changed": False, "msg": "openbsd sensors not present",
                    "data": {"discovery": []}}

        descr_map = _fetch_table(ctx, host, community, base, "2")
        type_map = _fetch_table(ctx, host, community, base, "3")
        val_map = _fetch_table(ctx, host, community, base, "5")
        unit_map = _fetch_table(ctx, host, community, base, "6")
        state_map = _fetch_table(ctx, host, community, base, "7")

        rows = []
        for idx in descr_map:
            if idx not in type_map:
                continue
            rows.append([
                descr_map.get(idx, ""),
                type_map.get(idx, ""),
                val_map.get(idx, ""),
                unit_map.get(idx, ""),
                state_map.get(idx, ""),
            ])

        section = _build_section(rows)
        discovery = _discover_voltage(section)
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    descr_map = _fetch_table(ctx, host, community, base, "2")
    target_idx = None
    for idx, val in descr_map.items():
        if val == item:
            target_idx = idx
            break

    if target_idx == None:
        return {
            "changed": False,
            "msg": "voltage sensor not found: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "", "item": item},
        }

    value_raw = _fetch_scalar(ctx, host, community, base + ".5." + target_idx)
    type_raw = _fetch_scalar(ctx, host, community, base + ".3." + target_idx)
    if value_raw == None or type_raw == None:
        return {
            "changed": False,
            "msg": "voltage sensor not found: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "", "item": item},
        }

    if type_raw != "2":
        return {
            "changed": False,
            "msg": "not a voltage sensor: " + str(item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "", "item": item},
        }

    unit_raw = _fetch_scalar(ctx, host, community, base + ".6." + target_idx)
    state_raw = _fetch_scalar(ctx, host, community, base + ".7." + target_idx)

    value = _safe_float(value_raw)
    unit = unit_raw if unit_raw != None else ""
    state_code = state_raw if state_raw != None else "0"
    sensor_state = _OPENBSD_MAP_STATE.get(state_code, "UNKNOWN")

    levels = params.get("levels", None)
    final_state = sensor_state
    if levels and type(value) == "float":
        warn = levels[0] if len(levels) > 0 else 0
        crit = levels[1] if len(levels) > 1 else 0
        if crit != 0:
            if value >= crit:
                final_state = "CRIT"
            elif warn != 0 and value >= warn:
                final_state = "WARN"
        if crit != 0 and value <= (0 - crit):
            final_state = "CRIT"
        elif warn != 0 and value <= (0 - warn):
            final_state = "WARN"

    summary = "%s %s %s" % (item, str(value), unit) if unit else "%s %s" % (item, str(value))
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": final_state,
            "metrics": {"voltage": _num(value)},
            "details": "sensor state: " + state_code,
            "item": item,
        },
    }