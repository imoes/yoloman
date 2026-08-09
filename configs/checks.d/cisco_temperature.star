def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx)
    return _check(ctx, params)

_BASE_ENT_PHYSICAL = ".1.3.6.1.2.1.47.1.1.1.1"
_BASE_ENT_SENSOR = ".1.3.6.1.4.1.9.9.91.1.1.1.1"
_BASE_CISCO_ENV_MON = ".1.3.6.1.4.1.9.9.13.1.3.1"

SENSOR_TYPES = {
    "1": "other", "2": "unknown", "3": "voltsAC", "4": "voltsDC",
    "5": "amperes", "6": "watts", "7": "hertz", "8": "celsius",
    "9": "parentRH", "10": "rpm", "11": "cmm", "12": "truthvalue",
    "13": "specialEnum", "14": "dBm"
}

SCALE_EXPONENTS = {
    "1": -24, "2": -21, "3": -18, "4": -15, "5": -12, "6": -9,
    "7": -6, "8": -3, "9": 0, "10": 3, "11": 6, "12": 9,
    "13": 12, "14": 18, "15": 15, "16": 21, "17": 24
}

SENSOR_STATE_MAP = {"1": (0, "OK"), "2": (3, "unavailable"), "3": (2, "non-operational")}
ENV_MON_STATE_MAP = {
    "1": (0, "normal"), "2": (1, "warning"), "3": (2, "critical"),
    "4": (2, "shutdown"), "5": (3, "not present"), "6": (2, "not functioning")
}

def _walk_snmp(ctx, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", base_oid])
    return res.stdout if res.rc == 0 else ""

def _parse_snmp_lines(lines):
    result = []
    for line in lines.splitlines():
        if "=" not in line:
            continue
        parts = line.strip().split("=", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
        val = value_part.strip()
        if ": " in val:
            _, val = val.split(": ", 1)
            val = val.strip()
        result.append((suffix, val))
    return result

def _cisco_sensor_item(description, sensor_id):
    item = sensor_id
    if not description:
        return item
    parts = [x.strip() for x in description.split(",")]
    if len(parts) == 1:
        item = description
    elif "#" in parts[-1] or "Power" in parts[-1]:
        item = " ".join(parts)
    elif parts[-1].startswith("PS"):
        item = " ".join([parts[0], parts[-1].split(" ")[0]])
    elif len(parts) >= 2 and parts[-2].startswith("PS"):
        item = " ".join(parts[:-2] + parts[-2].split(" ")[:-1])
    elif len(parts) >= 2 and parts[-2].startswith("Status"):
        item = " ".join(parts[:-2])
    else:
        item = " ".join(parts[:-1])

    if not item[-1].isdigit():
        item += " " + sensor_id

    return item.replace("#", " ")

def _pow(base, exp):
    if exp >= 0:
        result = 1
        for _ in range(exp):
            result = result * base
        return result
    else:
        # For negative exponents, compute 1/(base^|exp|)
        # Since Starlark doesn't have float division in a straightforward way for this use case,
        # and we know our exponents are small negative integers, we can handle it directly
        pos_exp = -exp
        denom = 1
        for _ in range(pos_exp):
            denom = denom * base
        return 1.0 / denom

def _discover(ctx):
    desc_oid = _BASE_ENT_PHYSICAL + ".7"
    desc_lines = _walk_snmp(ctx, desc_oid)
    descriptions = {}
    for suffix, val in _parse_snmp_lines(desc_lines):
        descriptions[suffix] = val.strip('"') if val.startswith('"') and val.endswith('"') else val

    status_lines = _walk_snmp(ctx, _BASE_ENT_SENSOR + ".5")
    status_map = {}
    for suffix, val in _parse_snmp_lines(status_lines):
        status_map[suffix] = val

    env_state_lines = _walk_snmp(ctx, _BASE_CISCO_ENV_MON + ".6")
    env_state_map = {}
    for suffix, val in _parse_snmp_lines(env_state_lines):
        env_state_map[suffix] = val

    value_lines = _walk_snmp(ctx, _BASE_ENT_SENSOR + ".4")
    sensor_states = {}
    for suffix, val in _parse_snmp_lines(value_lines):
        sensor_states[suffix] = val

    items = []
    discoverable_states = ["1", "2", "3", "4"]

    for sensor_id in sensor_states:
        if sensor_id not in descriptions:
            continue

        raw_state = status_map.get(sensor_id)
        if raw_state and raw_state in discoverable_states:
            item = descriptions[sensor_id]
            items.append({"item": item, "params": {}, "metrics": ["temperature"]})
        else:
            env_state = env_state_map.get(sensor_id)
            if env_state and env_state in discoverable_states:
                item = descriptions[sensor_id]
                items.append({"item": item, "params": {}, "metrics": ["temperature"]})

    if not items:
        perf_lines = _walk_snmp(ctx, _BASE_CISCO_ENV_MON + ".3")
        state_lines = _walk_snmp(ctx, _BASE_CISCO_ENV_MON + ".6")
        status_descrs = {}
        for suffix, val in _parse_snmp_lines(perf_lines):
            status_descrs[suffix] = val

        for suffix, state in _parse_snmp_lines(state_lines):
            sensor_id = suffix
            descr = status_descrs.get(sensor_id)
            if not descr:
                continue
            if state in discoverable_states:
                item = _cisco_sensor_item(descr, sensor_id)
                items.append({"item": item, "params": {}, "metrics": ["temperature"]})

    return {
        "changed": False,
        "msg": "discovered %d temperature sensors" % len(items),
        "data": {"discovery": items},
    }

def _check(ctx, params):
    item = params.get("item", "")
    if not item:
        fail("item must be provided")

    desc_oid = _BASE_ENT_PHYSICAL + ".7"
    state_oid = _BASE_ENT_SENSOR
    status_lines = _walk_snmp(ctx, state_oid + ".5")
    scale_lines = _walk_snmp(ctx, state_oid + ".2")
    precision_lines = _walk_snmp(ctx, state_oid + ".3")
    value_lines = _walk_snmp(ctx, state_oid + ".4")

    descriptions = {}
    for suffix, val in _parse_snmp_lines(_walk_snmp(ctx, desc_oid)):
        descriptions[suffix] = val.strip('"') if val.startswith('"') and val.endswith('"') else val

    sensor_data = {}
    for suffix, val in _parse_snmp_lines(value_lines):
        sensor_data.setdefault(suffix, {})["value"] = val

    for suffix, val in _parse_snmp_lines(status_lines):
        sensor_data.setdefault(suffix, {})["status"] = val

    for suffix, val in _parse_snmp_lines(scale_lines):
        sensor_data.setdefault(suffix, {})["scale"] = val

    for suffix, val in _parse_snmp_lines(precision_lines):
        sensor_data.setdefault(suffix, {})["precision"] = val

    perf_value_lines = _walk_snmp(ctx, _BASE_CISCO_ENV_MON + ".3")
    perf_state_lines = _walk_snmp(ctx, _BASE_CISCO_ENV_MON + ".6")
    perf_max_lines = _walk_snmp(ctx, _BASE_CISCO_ENV_MON + ".4")

    env_values = {}
    for suffix, val in _parse_snmp_lines(perf_value_lines):
        env_values[suffix] = val

    env_states = {}
    for suffix, val in _parse_snmp_lines(perf_state_lines):
        env_states[suffix] = val

    env_max = {}
    for suffix, val in _parse_snmp_lines(perf_max_lines):
        env_max[suffix] = val

    target_sensor_id = None
    for sid, desc in descriptions.items():
        if desc == item or _cisco_sensor_item(desc, sid) == item:
            target_sensor_id = sid
            break

    if not target_sensor_id:
        for sid, desc in env_values.items():
            if _cisco_sensor_item(desc, sid) == item:
                target_sensor_id = sid
                break

    if not target_sensor_id:
        return {
            "changed": False,
            "msg": "temperature sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if target_sensor_id in sensor_data:
        data = sensor_data[target_sensor_id]
        status = data.get("status", "0")

        if status in SENSOR_STATE_MAP:
            state, state_readable = SENSOR_STATE_MAP[status]
        else:
            state, state_readable = (3, "unknown[" + status + "]")

        if status != "1":
            return {
                "changed": False,
                "msg": "Status: " + state_readable,
                "data": {"state": state, "metrics": {}, "details": ""},
            }

        raw_value_str = data.get("value", "0")
        scale_str = data.get("scale", "9")
        precision_str = data.get("precision", "0")

        if not raw_value_str.isdigit() or not scale_str.isdigit() or not precision_str.isdigit():
            return {
                "changed": False,
                "msg": "reading invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

        raw_value = float(raw_value_str)
        scale = int(scale_str)
        precision = int(precision_str)

        exponent = SCALE_EXPONENTS.get(str(scale), 0)
        factor = _pow(10, exponent - precision)
        reading = raw_value * factor

        warn = params.get("levels", (None, None))
        warn_upper = warn[0] if warn and len(warn) > 0 and warn[0] != None else None
        crit_upper = warn[1] if warn and len(warn) > 1 and warn[1] != None else None
        dev_levels_upper = (warn_upper, crit_upper) if warn_upper != None else None
        dev_levels_lower = None

        state, msg = _compute_temperature_state(reading, dev_levels_upper, dev_levels_lower)
        metrics = {"temperature": reading}

        return {
            "changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""},
        }

    if target_sensor_id in env_values:
        temp_str = env_values.get(target_sensor_id, "0")
        state_raw = env_states.get(target_sensor_id, "0")
        max_temp_str = env_max.get(target_sensor_id, "0")

        if state_raw in ENV_MON_STATE_MAP:
            state, state_readable = ENV_MON_STATE_MAP[state_raw]
        else:
            state, state_readable = (3, "unknown[" + state_raw + "]")

        if state_raw not in ["1", "2", "3", "4"]:
            return {
                "changed": False,
                "msg": "Status: " + state_readable,
                "data": {"state": state, "metrics": {}, "details": ""},
            }

        warn_upper = None
        crit_upper = None
        if max_temp_str.isdigit():
            max_val = int(max_temp_str)
            warn_upper = float(max_val)
            crit_upper = float(max_val)

        warn = params.get("levels", (None, None))
        if warn and len(warn) > 0 and warn[0] != None:
            warn_upper = warn[0]
        if warn and len(warn) > 1 and warn[1] != None:
            crit_upper = warn[1]

        dev_levels_upper = (warn_upper, crit_upper) if warn_upper != None else None
        dev_levels_lower = None

        if not temp_str.isdigit():
            return {
                "changed": False,
                "msg": "reading invalid",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

        reading = float(temp_str)
        state, msg = _compute_temperature_state(reading, dev_levels_upper, dev_levels_lower)
        metrics = {"temperature": reading}

        return {
            "changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""},
        }

    return {
        "changed": False,
        "msg": "no data for sensor",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }

def _compute_temperature_state(reading, levels_upper, levels_lower):
    if levels_upper:
        warn_upper, crit_upper = levels_upper
        if crit_upper != None and reading >= crit_upper:
            return 2, "critical (running at %d C)" % int(reading)
        if warn_upper != None and reading >= warn_upper:
            return 1, "warning (running at %d C)" % int(reading)

    if levels_lower:
        warn_lower, crit_lower = levels_lower
        if crit_lower != None and reading <= crit_lower:
            return 2, "critical (running at %d C)" % int(reading)
        if warn_lower != None and reading <= warn_lower:
            return 1, "warning (running at %d C)" % int(reading)

    return 0, "OK (running at %d C)" % int(reading)