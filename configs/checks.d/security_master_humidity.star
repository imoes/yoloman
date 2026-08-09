def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    if params.get("_discover"):
        detect = _snmp_get_raw(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if detect == None:
            return {"changed": False, "msg": "security_master device not present",
                    "data": {"discovery": []}}
        if not detect.startswith("1.3.6.1.4.1.35491"):
            return {"changed": False, "msg": "not a security_master device",
                    "data": {"discovery": []}}

        rows = _walk_humidity_names(ctx, host, community)
        discovery = []
        for idx, name in rows:
            discovery.append({
                "item": name,
                "params": {"levels": [30, 70], "levels_lower": [0, 0]},
                "metrics": ["humidity"],
            })

        return {
            "changed": False,
            "msg": "discovered %d sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    detect = _snmp_get_raw(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if detect == None:
        return {"changed": False, "msg": "not a security_master device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not detect.startswith("1.3.6.1.4.1.35491"):
        return {"changed": False, "msg": "not a security_master device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_num = _find_sensor_by_name(ctx, host, community, item)
    if sensor_num == "":
        return {"changed": False,
                "msg": "sensor '%s' not found in SNMP output" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_id = _snmp_get_int(ctx, host, community,
                              ".1.3.6.1.4.1.35491.30.3.%s.1.0" % sensor_num)
    if sensor_id != 60:
        return {"changed": False,
                "msg": "sensor '%s' is not a humidity sensor" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = _snmp_get_float(ctx, host, community,
                            ".1.3.6.1.4.1.35491.30.3.%s.2.0" % sensor_num)
    alarm = _snmp_get_int(ctx, host, community,
                          ".1.3.6.1.4.1.35491.30.3.%s.6.0" % sensor_num)
    crit_low = _snmp_get_int(ctx, host, community,
                             ".1.3.6.1.4.1.35491.30.3.%s.7.0" % sensor_num) / 1000.0
    warn_low = _snmp_get_int(ctx, host, community,
                             ".1.3.6.1.4.1.35491.30.3.%s.8.0" % sensor_num) / 1000.0
    warn_high = _snmp_get_int(ctx, host, community,
                              ".1.3.6.1.4.1.35491.30.3.%s.9.0" % sensor_num) / 1000.0
    crit_high = _snmp_get_int(ctx, host, community,
                              ".1.3.6.1.4.1.35491.30.3.%s.10.0" % sensor_num) / 1000.0

    p_levels = params.get("levels")
    p_levels_lower = params.get("levels_lower")

    if alarm != None and alarm > -1:
        if not p_levels:
            p_levels = [warn_high, crit_high]
        if not p_levels_lower:
            p_levels_lower = [warn_low, crit_low]

    state = "OK"
    msg = "Humidity: %s %%" % _fmt(value)
    if value == None:
        state = "UNKNOWN"
        msg = "No value for sensor"
    else:
        upper_warn = _level(p_levels, 0)
        upper_crit = _level(p_levels, 1)
        lower_warn = _level(p_levels_lower, 0)
        lower_crit = _level(p_levels_lower, 1)
        if _above(upper_crit, value) or _below(lower_crit, value):
            state = "CRIT"
        elif _above(upper_warn, value) or _below(lower_warn, value):
            state = "WARN"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"humidity": value if value != None else 0},
            "details": "",
        },
    }

def _to_int(s):
    s = str(s).strip()
    if s == "" or s == None:
        return 0
    neg = False
    body = s
    if body.startswith("-"):
        neg = True
        body = body[1:]
    if not body.isdigit():
        return 0
    v = 0
    for c in body:
        v = v * 10 + _DIGITS_ORD.get(c, 0)
    return -v if neg else v

_DIGITS_ORD = {"0": 0, "1": 1, "2": 2, "3": 3, "4": 4,
               "5": 5, "6": 6, "7": 7, "8": 8, "9": 9}

def _fmt(v):
    if v == None:
        return "none"
    return str(v)

def _level(levels, idx):
    if levels == None:
        return None
    if idx < 0 or idx >= len(levels):
        return None
    return levels[idx]

def _above(crit, value):
    if crit == None or value == None:
        return False
    return value >= crit

def _below(crit, value):
    if crit == None or value == None:
        return False
    return value <= crit

def _snmp_get_raw(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _snmp_get_int(ctx, host, community, oid):
    raw = _snmp_get_raw(ctx, host, community, oid)
    if raw == None or raw == "":
        return None
    parts = raw.split(" ")
    if len(parts) > 1:
        return _to_int(parts[-1])
    return _to_int(raw)

def _snmp_get_float(ctx, host, community, oid):
    raw = _snmp_get_raw(ctx, host, community, oid)
    if raw == None or raw == "":
        return None
    val = raw
    # Strip a possible trailing type tag like 'INTEGER: 42'
    colon = val.find(": ")
    if colon != -1:
        val = val[colon + 2:]
    num = val.strip()
    if num == "" or num == None:
        return None
    if _is_float(num):
        return float(num)
    return None

def _is_float(s):
    s = str(s).strip()
    if s == "":
        return False
    if s.startswith("-") or s.startswith("+"):
        s = s[1:]
    if s == "":
        return False
    if "." in s:
        parts = s.split(".")
        if len(parts) != 2:
            return False
        int_part = parts[0]
        frac_part = parts[1]
        if int_part != "" and not int_part.isdigit():
            return False
        if frac_part == "":
            return False
        return frac_part.isdigit()
    return s.isdigit()

def _walk_humidity_names(ctx, host, community):
    base = ".1.3.6.1.4.1.35491.30.3"
    walk_oid = base + ".5"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, walk_oid],
        mutates=False,
    )
    out = []
    if res.rc != 0:
        return out
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        space = line.find(" ")
        if space == -1:
            continue
        full_oid = line[:space]
        value = line[space + 1:]
        # index is the suffix after the column base
        suffix = full_oid[len(walk_oid):]
        if suffix == "" or suffix == None:
            continue
        # suffix looks like ".<num>.5.0" -> extract sensor number
        idx = suffix.split(".")
        # idx[0] is empty (leading dot), idx[1] is the sensor number
        if len(idx) < 2:
            continue
        sensor_num = idx[1]
        out.append((sensor_num, value))
    return out

def _find_sensor_by_name(ctx, host, community, target_name):
    rows = _walk_humidity_names(ctx, host, community)
    for sensor_num, name in rows:
        if name == target_name:
            return sensor_num
    return ""