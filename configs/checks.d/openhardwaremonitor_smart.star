def _create_full_name(parent, name):
    parent = parent.replace("intelcpu", "cpu")
    parent = parent.replace("amdcpu", "cpu")
    parent = parent.replace("genericcpu", "cpu")
    name = name.replace("CPU ", "")
    name = name.replace("Temperature", "")
    parent = parent.replace("/", "")
    return (parent + " " + name).strip()


def _to_float(s):
    if s == None or s == "":
        return None
    cleaned = s.strip()
    if cleaned == "":
        return None
    has_digit = False
    seen_dot = False
    idx = 0
    if idx < len(cleaned) and (cleaned[idx] == "-" or cleaned[idx] == "+"):
        idx += 1
    while idx < len(cleaned):
        ch = cleaned[idx]
        if ch == "." and not seen_dot:
            seen_dot = True
        elif ch >= "0" and ch <= "9":
            has_digit = True
        else:
            return None
        idx += 1
    if not has_digit:
        return None
    return float(cleaned)


_openhardwaremonitor_traits = {
    "Clock": {"unit": " MHz", "factor": 1.0, "perf_var": "clock"},
    "Temperature": {"unit": "°C", "factor": 1.0},
    "Power": {"unit": " W", "factor": 1.0, "perf_var": "w"},
    "Fan": {"unit": " RPM", "factor": 1.0},
    "Level": {"unit": "%", "factor": 1.0},
    "Voltage": {"unit": " V", "factor": 1.0},
    "Load": {"unit": "%", "factor": 1.0},
    "Flow": {"unit": " L/h", "factor": 1.0},
    "Control": {"unit": "%", "factor": 1.0},
    "Factor": {"unit": "1", "factor": 1.0},
    "Data": {"unit": " B", "factor": 1073741824.0},
}


_openhardwaremonitor_smart_readings = [
    {"name": "Remaining Life", "key": "remaining_life", "lower_bounds": True},
]


_smart_default_levels = {"remaining_life": (30.0, 10.0)}


def _parse_sensor_line(line):
    if len(line) == 5:
        _index, name, parent, sensor_type, value = line
        wmistatus = "OK"
    elif len(line) == 6:
        _index, name, parent, sensor_type, value, wmistatus = line
    else:
        return None
    traits = _openhardwaremonitor_traits.get(sensor_type, {"unit": "", "factor": 1.1})
    reading = _to_float(value)
    if reading == None:
        return None
    reading = reading * traits.get("factor", 1.0)
    return {
        "reading": reading,
        "unit": traits.get("unit", ""),
        "perf_var": traits.get("perf_var"),
        "WMIstatus": wmistatus,
    }


def _gather_openhardwaremonitor_data(ctx):
    return None


def _parse_section(raw_lines):
    parsed = {}
    for line in raw_lines:
        if len(line) == 0:
            continue
        if line[0] == "Index":
            continue
        sensor = _parse_sensor_line(line)
        if sensor == None:
            continue
        name = line[1]
        parent = line[2]
        sensor_type = line[3]
        full_name = _create_full_name(parent, name)
        bucket = parsed.setdefault(sensor_type, {})
        if full_name not in bucket:
            bucket[full_name] = sensor
    return parsed


def _expect_order(a, b, c):
    arglist = [a, b, c]
    indexed = sorted(range(len(arglist)), key = lambda i: arglist[i])
    distance = 0
    for pos in range(len(indexed)):
        orig_idx = indexed[pos]
        d = abs(pos - orig_idx)
        if d > distance:
            distance = d
    state_map = {0: "OK", 1: "WARN", 2: "CRIT"}
    return state_map.get(distance, "UNKNOWN")


def _worst_state(state_a, state_b):
    order = ["OK", "WARN", "CRIT", "UNKNOWN"]
    ia = order.index(state_a) if state_a in order else 3
    ib = order.index(state_b) if state_b in order else 3
    idx = ia if ia > ib else ib
    if idx < len(order):
        return order[idx]
    return "UNKNOWN"


def _grade_lower(reading, warn, crit):
    return _expect_order(crit, warn, reading)


def _grade_upper(reading, warn, crit):
    return _expect_order(reading, warn, crit)


def main(ctx, params):
    if params.get("_discover"):
        section = _gather_openhardwaremonitor_data(ctx)
        if section == None:
            return {
                "changed": False,
                "msg": "no OpenHardwareMonitor data source found",
                "data": {"discovery": []},
            }
        devices = set()
        bucket = section.get("Level", {})
        for key in bucket:
            if "hdd" in key:
                dev = key.split(" ")[0]
                devices.add(dev)
        out = []
        for dev in devices:
            out.append({
                "item": dev,
                "params": {"remaining_life": (30.0, 10.0)},
                "metrics": ["remaining_life"],
            })
        return {
            "changed": False,
            "msg": "discovered %d devices" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    section = _gather_openhardwaremonitor_data(ctx)
    if section == None:
        return {
            "changed": False,
            "msg": "no OpenHardwareMonitor data source found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    summaries = []
    metrics = {}
    worst = "OK"
    bucket = section.get("Level", {})
    for reading in _openhardwaremonitor_smart_readings:
        reading_name = item + " " + reading["name"]
        if reading_name not in bucket:
            continue
        data = bucket[reading_name]
        if data["WMIstatus"].lower() == "timeout":
            return {
                "changed": False,
                "msg": "WMI query timed out",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        key = reading["key"]
        levels = params.get(key)
        if levels == None:
            levels = _smart_default_levels.get(key)
        if levels == None:
            continue
        warn, crit = levels[0], levels[1]
        if reading.get("lower_bounds"):
            state = _grade_lower(data["reading"], warn, crit)
        else:
            state = _grade_upper(data["reading"], warn, crit)
        worst = _worst_state(worst, state)
        summary = "%s %f%s" % (reading["name"], data["reading"], data["unit"])
        summaries.append(summary)
        pv = data.get("perf_var")
        mname = pv if pv != None else key
        metrics[mname] = data["reading"]

    if len(summaries) == 0:
        return {
            "changed": False,
            "msg": "no SMART reading found for device " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    msg = " | ".join(summaries)
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": worst, "metrics": metrics, "details": msg},
    }