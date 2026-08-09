# ===== checkmk -> starlark translation: aruba_sw_temp =====

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1.5",
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no aruba temperature sensors found",
                    "data": {"discovery": []}}
        entries = parse_snmp_walk(res.stdout)
        discovery = []
        for oid, value in entries.items():
            name = value
            index = oid_suffix(oid, ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1.5")
            if not index:
                continue
            state_res = ctx.run([
                "snmpget", "-v2c", "-c", params.get("community", "public"),
                "-Oqv", params.get("host", "localhost"),
                ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1.6." + index,
            ], mutates=False)
            if state_res.rc != 0 or not state_res.stdout:
                continue
            state = strip_snmp_value(state_res.stdout)
            if state == "absent":
                continue
            discovery.append({
                "item": name,
                "params": {"levels": "default", "input_unit": "c"},
                "metrics": ["temperature"],
            })
        return {"changed": False,
                "msg": "discovered %d temperature sensors" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    walk_res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-Oqn", "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1.5",
    ], mutates=False)
    if walk_res.rc != 0:
        return {"changed": False, "msg": "no aruba temperature sensors found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    entries = parse_snmp_walk(walk_res.stdout)
    target_index = None
    for oid, value in entries.items():
        if value == item:
            target_index = oid_suffix(oid, ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1.5")
            break
    if target_index == None:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1.6." + target_index,
    ], mutates=False)
    cur_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1.7." + target_index,
    ], mutates=False)
    min_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1.8." + target_index,
    ], mutates=False)
    max_res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.47196.4.1.1.3.11.3.1.1.9." + target_index,
    ], mutates=False)
    for r in [state_res, cur_res, min_res, max_res]:
        if r.rc != 0:
            return {"changed": False, "msg": "failed to read sensor data for " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = strip_snmp_value(state_res.stdout)
    cur = safe_div1000(cur_res.stdout)
    mn = safe_div1000(min_res.stdout)
    mx = safe_div1000(max_res.stdout)

    sensor_status = _sensor_status(status)
    warn, crit = get_aruba_default_temp(item)
    input_unit = "c"
    levels = params.get("levels", (warn, crit))
    if type(levels) == "list" and len(levels) == 2:
        warn, crit = levels[0], levels[1]

    metric_state = "OK"
    metric_value = 0.0
    details_lines = []
    if status in ("fault", "normal", "warning", "emergency"):
        if status == "emergency":
            metric_state = "CRIT"
        elif status in ("fault", "warning"):
            metric_state = "WARN"
        if cur != None:
            metric_value = cur
            if cur >= crit:
                metric_state = "CRIT"
            elif cur >= warn:
                metric_state = "WARN"
    if status in ("absent",) or status == None:
        metric_state = "UNKNOWN"

    details_lines.append("Sensor name: %s" % item)
    details_lines.append("Device status: %s" % status)
    details_lines.append("Current temperature: %s %s" % (render_temp(cur, input_unit),
                                                           temp_unitsym(input_unit)))
    details_lines.append("Min temperature: %s %s" % (render_temp(mn, input_unit),
                                                     temp_unitsym(input_unit)))
    details_lines.append("Max temperature: %s %s" % (render_temp(mx, input_unit),
                                                     temp_unitsym(input_unit)))

    metrics = {}
    if metric_value != 0.0:
        metrics["temperature"] = metric_value

    return {"changed": False,
            "msg": "Temperature: %s %s (status: %s)" % (
                render_temp(cur, input_unit), temp_unitsym(input_unit), status),
            "data": {"state": metric_state, "metrics": metrics,
                     "details": "\n".join(details_lines)}}


def parse_snmp_walk(stdout):
    entries = {}
    lines = stdout.split("\n")
    for line in lines:
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        entries[oid] = value
    return entries


def oid_suffix(oid, base):
    blen = len(base)
    if oid[:blen] != base:
        return ""
    rest = oid[blen:]
    if len(rest) == 0:
        return ""
    if rest[0] == ".":
        return rest[1:]
    return rest


def strip_snmp_value(s):
    s = s.strip()
    colon = s.find(":")
    if colon != -1:
        s = s[colon + 1:].strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    return s


def safe_div1000(s):
    v = strip_snmp_value(s)
    if v == "":
        return None
    neg = False
    i = 0
    if v[0] == "-":
        neg = True
        i = 1
    digits = ""
    seen_dot = False
    while i < len(v):
        c = v[i]
        if c >= "0" and c <= "9":
            digits = digits + c
        elif c == "." and not seen_dot:
            digits = digits + c
            seen_dot = True
        else:
            break
        i = i + 1
    if digits == "" or digits == "." or digits == "-":
        return None
    val = float(digits)
    val = val / 1000.0
    if neg:
        val = -val
    return val


def temp_unitsym(unit):
    if unit == "f":
        return "F"
    if unit == "k":
        return "K"
    return "C"


def render_temp(value, unit):
    if value == None:
        return "?"
    f = unit == "f"
    k = unit == "k"
    if f:
        value = (value * 9.0 / 5.0) + 32.0
    elif k:
        value = value + 273.15
    return "%f" % value


def _sensor_status(name):
    if name == "fault":
        return "fault"
    if name == "normal":
        return "normal"
    if name == "emergency":
        return "emergency"
    if name == "absent":
        return "absent"
    if name == "warning":
        return "warning"
    return None


_WARN_DEFAULTS = {
    "CPU": 80, "ASIC": 80, "DDR": 60, "Inlet": 30, "PHY": 80,
    "Internal": 45, "IBC": 45, "PCIE": 55, "Board-rear": 45,
    "Exhaust": 45, "MAINBOARD": 35, "DDR_INLET": 40,
}
_CRIT_DEFAULTS = {
    "CPU": 90, "ASIC": 90, "DDR": 70, "Inlet": 40, "PHY": 90,
    "Internal": 50, "IBC": 50, "PCIE": 60, "Board-rear": 50,
    "Exhaust": 50, "MAINBOARD": 40, "DDR_INLET": 45,
}


def get_aruba_default_temp(name):
    if "CPU" in name:
        return (_WARN_DEFAULTS["CPU"], _CRIT_DEFAULTS["CPU"])
    if "ASIC" in name:
        return (_WARN_DEFAULTS["ASIC"], _CRIT_DEFAULTS["ASIC"])
    if "DDR" in name:
        if "Inlet" in name:
            return (_WARN_DEFAULTS["DDR_INLET"], _CRIT_DEFAULTS["DDR_INLET"])
        return (_WARN_DEFAULTS["DDR"], _CRIT_DEFAULTS["DDR"])
    if "Inlet" in name:
        return (_WARN_DEFAULTS["INLET"], _CRIT_DEFAULTS["INLET"])
    if "PHY" in name:
        return (_WARN_DEFAULTS["PHY"], _CRIT_DEFAULTS["PHY"])
    if "Internal" in name:
        return (_WARN_DEFAULTS["INTERNAL"], _CRIT_DEFAULTS["INTERNAL"])
    if "IBC" in name:
        return (_WARN_DEFAULTS["IBC"], _CRIT_DEFAULTS["IBC"])
    if "PCIE" in name:
        return (_WARN_DEFAULTS["PCIE"], _CRIT_DEFAULTS["PCIE"])
    if "Board-rear" in name:
        return (_WARN_DEFAULTS["BOARD_REAR"], _CRIT_DEFAULTS["BOARD_REAR"])
    if "Exhaust" in name:
        return (_WARN_DEFAULTS["EXHAUST"], _CRIT_DEFAULTS["EXHAUST"])
    return (_WARN_DEFAULTS["MAINBOARD"], _CRIT_DEFAULTS["MAINBOARD"])