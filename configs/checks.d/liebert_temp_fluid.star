def _is_liebert_device(ctx, host, community):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Onqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False
    oid = res.stdout.strip()
    return oid.startswith(".1.3.6.1.4.1.476.1.42")

def _walk_table(ctx, host, community, base):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-Ov", host, base], mutates=False)
    if res.rc != 0:
        return {}
    rows = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        val = parts[1].strip()
        if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
            val = val[1:-1]
        idx = oid[len(base) + 1:]
        rows[idx] = val
    return rows

def _temp_to_celsius(reading, unit):
    u = unit.replace("deg ", "").lower()
    if u == "c" or u == "%":
        return reading
    if u == "f":
        return (reading - 32) * (5.0 / 9.0)
    if u == "k":
        return reading - 273.15
    return reading

def _safe_float(s):
    s = s.strip()
    if s == "" or s == "-":
        return None
    neg = False
    i = 0
    if s[0] == "-":
        neg = True
        i = 1
    elif s[0] == "+":
        i = 1
    digits = "0123456789"
    seen_dot = False
    is_num = False
    while i < len(s):
        c = s[i]
        if c in digits:
            is_num = True
            i = i + 1
        elif c == "." and not seen_dot and i > (1 if neg else 0):
            seen_dot = True
            i = i + 1
        elif c == "e" or c == "E":
            if i + 1 < len(s) and s[i + 1] in "+-":
                i = i + 2
            else:
                i = i + 1
        elif c in "+-" and i > 0 and s[i - 1] in "eE":
            i = i + 1
        else:
            break
    if not is_num or i != len(s):
        return None
    val = float(s)
    if neg:
        val = -val
    return val

def _parse_section(ctx, host, community):
    base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    label_rows = _walk_table(ctx, host, community, base + ".10")
    value_rows = _walk_table(ctx, host, community, base + ".20")
    unit_rows = _walk_table(ctx, host, community, base + ".30")

    readings = {}
    upper_warn = None
    upper_crit = None
    lower_warn = None
    lower_crit = None

    for idx in label_rows:
        name = label_rows[idx]
        if not name:
            continue
        raw_val = value_rows.get(idx, "")
        unit_val = unit_rows.get(idx, "")
        reading = _safe_float(raw_val)
        if reading == None:
            continue
        reading_c = _temp_to_celsius(reading, unit_val)
        readings[name] = reading_c

    if "Supply Fluid Over Temp Alarm Threshold" in readings:
        upper_warn = readings.pop("Supply Fluid Over Temp Alarm Threshold")
    if "Supply Fluid Over Temp Warning Threshold" in readings:
        upper_crit = readings.pop("Supply Fluid Over Temp Warning Threshold")
    if "Supply Fluid Under Temp Alarm Threshold" in readings:
        lower_warn = readings.pop("Supply Fluid Under Temp Alarm Threshold")
    if "Supply Fluid Under Temp Warning Threshold" in readings:
        lower_crit = readings.pop("Supply Fluid Under Temp Warning Threshold")

    upper_levels = None
    if upper_warn != None and upper_crit != None:
        if 0 in (upper_warn, upper_crit):
            upper_warn = max(upper_warn, upper_crit)
            upper_crit = upper_warn
        upper_levels = (upper_warn, upper_crit)

    lower_levels = None
    if lower_warn != None and lower_crit != None:
        lower_levels = (lower_warn, lower_crit)

    return {"readings": readings, "upper_levels": upper_levels, "lower_levels": lower_levels}

def _grade_temp(value, warn, crit, upper_levels, lower_levels):
    if upper_levels != None:
        uw, uc = upper_levels
        if value >= uc:
            return "CRIT"
        if value >= uw:
            return "WARN"
    if lower_levels != None:
        lw, lc = lower_levels
        if value <= lc:
            return "CRIT"
        if value <= lw:
            return "WARN"
    if warn != None and crit != None:
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
    return "OK"

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if not _is_liebert_device(ctx, host, community):
        return {"changed": False, "msg": "no Liebert device found", "data": {"discovery": []}}

    if params.get("_discover"):
        section = _parse_section(ctx, host, community)
        discovery = []
        for name in section["readings"]:
            if "Set Point" in name:
                discovery.append({"item": name, "params": {}, "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _parse_section(ctx, host, community)
    reading = section["readings"].get(item)
    if reading == None:
        return {"changed": False, "msg": "no reading for item: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("warn", None)
    crit = params.get("crit", None)
    state = _grade_temp(reading, warn, crit, section["upper_levels"], section["lower_levels"])
    return {"changed": False, "msg": "%s: %f C" % (item, reading), "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}