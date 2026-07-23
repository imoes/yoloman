def _parse_snmp_table(res):
    parsed = {}
    used_names = set()

    def get_item_name(name):
        counter = 2
        new_name = name
        while True:
            if new_name in used_names:
                new_name = "%s %d" % (name, counter)
                counter += 1
            else:
                used_names.add(new_name)
                break
        return new_name

    lines = res.stdout.splitlines()
    all_data = []
    for line in lines:
        if " = " not in line:
            continue
        label_part = line.split(" = ", 1)[0].strip()
        value_part = line.split(" = ", 1)[1].strip()
        if value_part.startswith("STRING:"):
            v = value_part[7:].strip().strip('"')
            all_data.append((label_part, v, "label"))
        elif value_part.startswith("INTEGER:") or value_part.startswith("Gauge32:"):
            v = value_part.split(":", 1)[1].strip()
            all_data.append((label_part, v, "value"))
        elif value_part.startswith("STRING:"):
            v = value_part[7:].strip().strip('"')
            all_data.append((label_part, v, "unit"))
        else:
            all_data.append((label_part, value_part, "other"))

    i = 0
    while i + 2 < len(all_data):
        label_oid = all_data[i][0]
        value_oid = all_data[i + 1][0]
        unit_oid = all_data[i + 2][0]
        if not (label_oid.endswith(".5283") and value_oid.endswith(".5283") and unit_oid.endswith(".5283")):
            i += 1
            continue
        label = all_data[i][1]
        value_str = all_data[i + 1][1]
        unit = all_data[i + 2][1]
        i += 3
        if not label:
            continue
        name = get_item_name(label)
        parsed[name] = (value_str, unit)

    return parsed

def _temperature_to_celsius(reading_str, unit):
    if not reading_str:
        return None
    # Guard instead of try/except
    if reading_str.isdigit() or (reading_str.startswith("-") and reading_str[1:].isdigit()):
        reading = int(reading_str)
    elif reading_str.find(".") != -1:
        parts = reading_str.split(".")
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            reading = float(reading_str)
        else:
            return None
    else:
        return None

    u = unit.replace("deg ", "").lower()
    if u == "c" or u == "%":
        return reading
    elif u == "f":
        return (reading - 32) * (5.0 / 9.0)
    elif u == "k":
        return reading - 273.15
    else:
        return None

def _check_temperature(reading, params, dev_levels=None, dev_levels_lower=None):
    warn = params.get("levels_upper", (None, None))
    crit = params.get("levels_upper_critical", (None, None))
    if type(warn) == "list":
        warn = tuple(warn)
    if type(crit) == "list":
        crit = tuple(crit)
    if len(warn) != 2:
        warn = (None, None)
    if len(crit) != 2:
        crit = (None, None)
    if dev_levels != None and (dev_levels[0] != None or dev_levels[1] != None):
        warn = dev_levels
    if dev_levels_lower != None and (dev_levels_lower[0] != None or dev_levels_lower[1] != None):
        crit = dev_levels_lower

    state = "OK"
    details = []

    if warn[0] != None:
        if reading >= crit[1]:
            state = "CRIT"
        elif reading >= warn[0]:
            if state != "CRIT":
                state = "WARN"
        details.append("upper_warn=%s, upper_crit=%s" % (str(warn[0]), str(crit[1])))

    lower_warn = params.get("levels_lower", (None, None))
    lower_crit = params.get("levels_lower_critical", (None, None))
    if type(lower_warn) == "list":
        lower_warn = tuple(lower_warn)
    if type(lower_crit) == "list":
        lower_crit = tuple(lower_crit)
    if len(lower_warn) != 2:
        lower_warn = (None, None)
    if len(lower_crit) != 2:
        lower_crit = (None, None)
    if dev_levels_lower != None:
        lower_warn = dev_levels_lower

    if lower_warn[0] != None:
        if reading <= lower_crit[1]:
            state = "CRIT"
        elif reading <= lower_warn[0]:
            if state != "CRIT":
                state = "WARN"
        details.append("lower_warn=%s, lower_crit=%s" % (str(lower_warn[0]), str(lower_crit[1])))

    return state, ", ".join(details) if details else ""

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

        parsed = _parse_snmp_table(res)
        upper_warn = parsed.pop("Supply Fluid Over Temp Alarm Threshold", None)
        upper_crit = parsed.pop("Supply Fluid Over Temp Warning Threshold", None)
        lower_warn = parsed.pop("Supply Fluid Under Temp Alarm Threshold", None)
        lower_crit = parsed.pop("Supply Fluid Under Temp Warning Threshold", None)

        upper_levels = None
        if upper_warn != None and upper_crit != None:
            uw = float(upper_warn[0]) if type(upper_warn) == "list" else float(upper_warn)
            uc = float(upper_crit[0]) if type(upper_crit) == "list" else float(upper_crit)
            if uw == 0 and uc == 0:
                uw = max(uw, uc)
                uc = uw
            upper_levels = (uw, uc)

        lower_levels = None
        if lower_warn != None and lower_crit != None:
            lw = float(lower_warn[0]) if type(lower_warn) == "list" else float(lower_warn)
            lc = float(lower_crit[0]) if type(lower_crit) == "list" else float(lower_crit)
            lower_levels = (lw, lc)

        items = []
        for name in parsed:
            if "Set Point" in name:
                items.append({"item": name, "params": {"warn": 25, "crit": 30},
                              "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d sensors" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parsed = _parse_snmp_table(res)
    upper_warn_val = parsed.pop("Supply Fluid Over Temp Alarm Threshold", None)
    upper_crit_val = parsed.pop("Supply Fluid Over Temp Warning Threshold", None)
    lower_warn_val = parsed.pop("Supply Fluid Under Temp Alarm Threshold", None)
    lower_crit_val = parsed.pop("Supply Fluid Under Temp Warning Threshold", None)

    upper_levels = None
    if upper_warn_val != None and upper_crit_val != None:
        uw = float(upper_warn_val[0]) if type(upper_warn_val) == "list" else float(upper_warn_val[0])
        uc = float(upper_crit_val[0]) if type(upper_crit_val) == "list" else float(upper_crit_val[0])
        if uw == 0 and uc == 0:
            uw = max(uw, uc)
            uc = uw
        upper_levels = (uw, uc)

    lower_levels = None
    if lower_warn_val != None and lower_crit_val != None:
        lw = float(lower_warn_val[0]) if type(lower_warn_val) == "list" else float(lower_warn_val[0])
        lc = float(lower_crit_val[0]) if type(lower_crit_val) == "list" else float(lower_crit_val[0])
        lower_levels = (lw, lc)

    if item not in parsed:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading_str, unit = parsed[item]
    reading = _temperature_to_celsius(reading_str, unit)
    if reading == None:
        return {"changed": False, "msg": "invalid reading or unit: " + reading_str + " " + unit,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("warn", 25)
    crit = params.get("crit", 30)
    dev_levels = upper_levels if upper_levels != None else (None, None)
    dev_levels_lower = lower_levels if lower_levels != None else (None, None)

    check_params = {
        "levels_upper": (warn, crit),
        "levels_upper_critical": (warn, crit),
        "levels_lower": (None, None),
        "levels_lower_critical": (None, None)
    }

    state, details = _check_temperature(reading, check_params, dev_levels, dev_levels_lower)
    return {
        "changed": False,
        "msg": "%s: %f deg C" % (item, reading),
        "data": {
            "state": state,
            "metrics": {"temperature": reading},
            "details": details
        }
    }