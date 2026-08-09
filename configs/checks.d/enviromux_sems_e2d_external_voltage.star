SENSOR_TYPE_NAMES = {
    "0": "undefined",
    "1": "temperature",
    "2": "humidity",
    "3": "power",
    "4": "lowVoltage",
    "5": "current",
    "6": "aclmvVoltage",
    "7": "aclmpVoltage",
    "8": "aclmpPower",
    "9": "water",
    "10": "smoke",
    "11": "vibration",
    "12": "motion",
    "13": "glass",
    "14": "door",
    "15": "keypad",
    "16": "panicButton",
    "17": "keyStation",
    "18": "digInput",
    "22": "light",
    "24": "dewpoint",
    "26": "tacDio",
    "36": "acVoltage",
    "37": "acCurrent",
    "38": "dcVoltage",
    "39": "dcCurrent",
    "41": "rmsVoltage",
    "42": "rmsCurrent",
    "43": "activePower",
    "44": "reactivePower",
    "513": "tempHum",
    "32767": "custom",
    "32769": "temperatureCombo",
    "32770": "humidityCombo",
    "540": "tempHum",
}

ENVIROMUX_CHECK_DEFAULT_PARAMETERS = {
    "levels": [15.0, 16.0],
    "levels_lower": [10.0, 9.0],
}


def _parse_oid_value(value_part):
    if value_part.startswith("STRING:"):
        return value_part[7:].strip().strip('"')
    else:
        idx = value_part.find(": ")
        if idx >= 0:
            return value_part[idx + 2:].strip()
        return value_part


def _to_float(s):
    if s == None:
        return None
    stripped = s.strip()
    if not stripped:
        return None
    # Check for valid float representation
    temp = stripped.replace('.', '').replace('-', '').replace('+', '').strip()
    if not temp.isdigit():
        return None
    return float(stripped)


def _discover(ctx, community, host):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.3699.1.1.9.1.5.1.1"
    ], mutates=False)
    lines = res.stdout.splitlines()
    out = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        parts = line.split(" = ")
        if len(parts) < 2:
            i += 1
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        sensor_value_str = _parse_oid_value(value_part)
        if sensor_value_str == "Not configured":
            i += 1
            continue
        if not sensor_value_str.isdigit():
            i += 1
            continue
        sensor_index = int(sensor_value_str)
        if i + 5 >= len(lines):
            break
        base_oid = oid_part.rsplit(".", 1)[0]
        sensor_type_oid = base_oid + ".2." + str(sensor_index)
        sensor_desc_oid = base_oid + ".3." + str(sensor_index)
        sensor_value_oid = base_oid + ".7." + str(sensor_index)
        sensor_min_oid = base_oid + ".11." + str(sensor_index)
        sensor_max_oid = base_oid + ".12." + str(sensor_index)
        sensor_type_line = ""
        sensor_desc_line = ""
        sensor_value_line = ""
        sensor_min_line = ""
        sensor_max_line = ""
        j = 1
        while j <= 5 and i + j < len(lines):
            l = lines[i + j].strip()
            if not l:
                j += 1
                continue
            o = l.split(" = ")[0].strip()
            v = l.split(" = ")[1].strip()
            if o == sensor_type_oid:
                sensor_type_line = _parse_oid_value(v)
            elif o == sensor_desc_oid:
                sensor_desc_line = _parse_oid_value(v)
            elif o == sensor_value_oid:
                sensor_value_line = _parse_oid_value(v)
            elif o == sensor_min_oid:
                sensor_min_line = _parse_oid_value(v)
            elif o == sensor_max_oid:
                sensor_max_line = _parse_oid_value(v)
            j += 1
        if not sensor_type_line or not sensor_desc_line or not sensor_value_line:
            i += 1
            continue
        sensor_type = SENSOR_TYPE_NAMES.get(sensor_type_line, "unknown")
        value_str = sensor_value_line
        if not value_str:
            i += 1
            continue
        value = _to_float(value_str)
        if value == None:
            i += 1
            continue
        min_val = None
        if sensor_min_line and sensor_min_line != "Not configured":
            min_val = _to_float(sensor_min_line)
        max_val = None
        if sensor_max_line and sensor_max_line != "Not configured":
            max_val = _to_float(sensor_max_line)
        if sensor_type in ["temperature", "power", "current", "temperatureCombo"]:
            value = value / 10.0
            if min_val != None:
                min_val = min_val / 10.0
            if max_val != None:
                max_val = max_val / 10.0
        sensor_name = sensor_desc_line + " " + str(sensor_index)
        out.append({"item": sensor_name, "params": {"levels": [15.0, 16.0], "levels_lower": [10.0, 9.0]}, "metrics": ["voltage"]})
        i += 1
    return out


def _check(ctx, community, host, item, levels, levels_lower):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.3699.1.1.9.1.5.1.1"
    ], mutates=False)
    lines = res.stdout.splitlines()
    sensor_value = None
    sensor_min = None
    sensor_max = None
    sensor_desc = ""
    sensor_type_line = ""
    sensor_value_str_raw = ""
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        parsed = _parse_oid_value(value_part)
        if parsed == "Not configured":
            continue
        if not parsed.isdigit():
            continue
        sensor_index = int(parsed)
        base_oid = oid_part.rsplit(".", 1)[0]
        sensor_type_oid = base_oid + ".2." + str(sensor_index)
        sensor_desc_oid = base_oid + ".3." + str(sensor_index)
        sensor_value_oid = base_oid + ".7." + str(sensor_index)
        sensor_min_oid = base_oid + ".11." + str(sensor_index)
        sensor_max_oid = base_oid + ".12." + str(sensor_index)
        if oid_part.startswith(sensor_desc_oid) and sensor_desc == "":
            sensor_desc = _parse_oid_value(value_part)
        if oid_part.startswith(sensor_type_oid) and sensor_type_line == "":
            sensor_type_line = _parse_oid_value(value_part)
        if oid_part.startswith(sensor_value_oid) and sensor_value == None:
            val_str = _parse_oid_value(value_part)
            if val_str:
                sensor_value = _to_float(val_str)
        if oid_part.startswith(sensor_min_oid) and sensor_min == None:
            val_str = _parse_oid_value(value_part)
            if val_str and val_str != "Not configured":
                sensor_min = _to_float(val_str)
        if oid_part.startswith(sensor_max_oid) and sensor_max == None:
            val_str = _parse_oid_value(value_part)
            if val_str and val_str != "Not configured":
                sensor_max = _to_float(val_str)
        if oid_part.startswith(sensor_value_oid) and sensor_value_str_raw == "":
            sensor_value_str_raw = parsed
    if sensor_value == None:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    sensor_name = sensor_desc + " " + str(sensor_value_str_raw)
    if sensor_name != item:
        return {
            "changed": False,
            "msg": "sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    sensor_type = SENSOR_TYPE_NAMES.get(sensor_type_line, "unknown")
    if sensor_type in ["temperature", "power", "current", "temperatureCombo"]:
        sensor_value = sensor_value / 10.0
        if sensor_min != None:
            sensor_min = sensor_min / 10.0
        if sensor_max != None:
            sensor_max = sensor_max / 10.0
    warn_upper = levels[0]
    crit_upper = levels[1]
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]
    state = "OK"
    if sensor_max != None and sensor_value >= sensor_max:
        state = "CRIT"
    elif sensor_value >= crit_upper:
        state = "CRIT"
    elif sensor_max != None and sensor_value >= sensor_max * 0.95 and crit_upper >= sensor_max:
        state = "WARN"
    elif sensor_value >= warn_upper:
        state = "WARN"
    elif sensor_min != None and sensor_value <= sensor_min:
        state = "CRIT"
    elif sensor_value <= crit_lower:
        state = "CRIT"
    elif sensor_min != None and sensor_value <= sensor_min * 1.05 and crit_lower <= sensor_min:
        state = "WARN"
    elif sensor_value <= warn_lower:
        state = "WARN"
    metrics = {"voltage": sensor_value}
    msg = "Input Voltage is %f V" % sensor_value
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if params.get("_discover"):
        discovery = _discover(ctx, community, host)
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery}
        }
    item = params.get("item", "")
    levels = params.get("levels", [15.0, 16.0])
    levels_lower = params.get("levels_lower", [10.0, 9.0])
    return _check(ctx, community, host, item, levels, levels_lower)