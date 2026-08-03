# allnet_ip_sensoric_humidity.check — translated from Checkmk checkmk.allnet_ip_sensoric_humidity

_HUMIDITY_LEVELS = (60.0, 65.0)
_HUMIDITY_LEVELS_LOWER = (40.0, 35.0)
_HUMIDITY_FUNCTION = "2"
_HUMIDITY_UNIT = "%"
_SENSOR_BASE = "1.3.6.1.4.1.31446.4.5.1"
_COL_FUNCTION = _SENSOR_BASE + ".1"
_COL_NAME = _SENSOR_BASE + ".2"
_COL_VALUE = _SENSOR_BASE + ".4"
_COL_UNIT = _SENSOR_BASE + ".5"

def _split_prefix(s, prefix):
    if s.startswith(prefix):
        return s[len(prefix):]
    return s

def _compose_item(sensor_id, sensor_data):
    num = _split_prefix(sensor_id, "sensor")
    name = sensor_data.get("name", "")
    if name != "":
        return name + " Sensor " + num
    return "Sensor " + num

def _is_humidity(sensor_data):
    func = sensor_data.get("function", "")
    if func == _HUMIDITY_FUNCTION:
        return True
    unit = sensor_data.get("unit", "")
    if unit != "" and unit == _HUMIDITY_UNIT:
        return True
    return False

def _grade_humidity(value, warn, crit, warn_low, crit_low):
    state = "OK"
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    elif value <= crit_low:
        state = "CRIT"
    elif value <= warn_low:
        state = "WARN"
    return state

def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        return None
    return res.stdout.strip()

def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.skipped:
        return []
    return [l for l in res.stdout.split("\n") if l != ""]

def _load_sensors(ctx, host, community):
    rows = {}
    for col_oid in (_COL_FUNCTION, _COL_NAME, _COL_VALUE, _COL_UNIT):
        for line in _snmp_walk(ctx, host, community, col_oid):
            sp = line.find(" ")
            if sp == -1:
                continue
            line_oid = line[:sp]
            line_val = line[sp + 1:]
            idx = ""
            if line_oid.startswith(col_oid + "."):
                idx = line_oid[len(col_oid) + 1:]
            if idx == "":
                continue
            sensor_id = "sensor" + idx
            row = rows.get(sensor_id, {})
            if col_oid == _COL_FUNCTION:
                row["function"] = line_val
            elif col_oid == _COL_NAME:
                row["name"] = line_val
            elif col_oid == _COL_VALUE:
                row["value"] = line_val
            elif col_oid == _COL_UNIT:
                row["unit"] = line_val
            rows[sensor_id] = row
    return rows

def _is_numeric(s):
    if s == "" or s == None:
        return False
    body = s
    if body.startswith("-"):
        body = body[1:]
    elif body.startswith("+"):
        body = body[1:]
    if body == "":
        return False
    parts = body.split(".")
    if len(parts) > 2:
        return False
    all_digits = True
    for p in parts:
        if p == "":
            if body == ".":
                all_digits = False
                break
            continue
        if not p.isdigit():
            all_digits = False
            break
    return all_digits

def _parse_value(raw):
    if raw == None or raw == "":
        return None
    s = raw
    if s.startswith('"') and s.endswith('"') and len(s) >= 2:
        s = s[1:-1]
    if s == "" or s == '""':
        return None
    if not _is_numeric(s):
        return None
    return float(s)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    discover = params.get("_discover", False)

    levels = params.get("levels", _HUMIDITY_LEVELS)
    levels_lower = params.get("levels_lower", _HUMIDITY_LEVELS_LOWER)
    warn = levels[0] if len(levels) >= 2 else _HUMIDITY_LEVELS[0]
    crit = levels[1] if len(levels) >= 2 else _HUMIDITY_LEVELS[1]
    warn_low = levels_lower[0] if len(levels_lower) >= 2 else _HUMIDITY_LEVELS_LOWER[0]
    crit_low = levels_lower[1] if len(levels_lower) >= 2 else _HUMIDITY_LEVELS_LOWER[1]

    probe = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _COL_FUNCTION],
        mutates=False,
    )
    if probe.rc == 127 or probe.skipped:
        if discover:
            return {"changed": False, "msg": "no SNMP available", "data": {"discovery": []}}
        return {"changed": False,
                "msg": "no allnet_ip_sensoric device reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if probe.rc != 0:
        if discover:
            return {"changed": False, "msg": "no sensor table", "data": {"discovery": []}}
        return {"changed": False,
                "msg": "snmpwalk for allnet_ip_sensoric failed (rc=%d)" % probe.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensors = _load_sensors(ctx, host, community)

    if discover:
        found = []
        for sensor_id, sensor_data in sensors.items():
            if _is_humidity(sensor_data):
                it = _compose_item(sensor_id, sensor_data)
                found.append({
                    "item": it,
                    "params": {
                        "levels": (warn, crit),
                        "levels_lower": (warn_low, crit_low),
                    },
                    "metrics": ["humidity"],
                })
        return {"changed": False, "msg": "discovered %d humidity sensors" % len(found),
                "data": {"discovery": found}}

    target_id = None
    for sensor_id, sensor_data in sensors.items():
        if _compose_item(sensor_id, sensor_data) == item:
            target_id = sensor_id
            break

    if target_id == None:
        return {"changed": False,
                "msg": "humidity sensor '" + item + "' not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor_data = sensors[target_id]
    if not _is_humidity(sensor_data):
        return {"changed": False,
                "msg": "sensor '" + item + "' is not a humidity sensor",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = _parse_value(sensor_data.get("value", ""))
    if value == None:
        return {"changed": False,
                "msg": "no readable humidity value for '" + item + "'",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = _grade_humidity(value, warn, crit, warn_low, crit_low)
    return {"changed": False,
            "msg": "Humidity: %f%%" % value,
            "data": {"state": state, "metrics": {"humidity": value}, "details": ""}}