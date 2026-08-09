def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)


_SNMP_BASE = "1.3.6.1.4.1.18248.20.1.2.1.1"
_SYS_DESCRIBRIB = "1.3.6.1.2.1.1.1.0"
_SYS_OID = "1.3.6.1.2.1.1.2.0"

_MAP_SENSOR_TYPE = {
    "1": "temp",
    "2": "humidity",
    "3": "dewpoint",
}

_MAP_UNITS = {
    "0": "c",
    "1": "f",
    "2": "k",
    "3": "percent",
}

_MAP_STATES = {
    "0": (0, "OK"),
    "1": (3, "not available"),
    "2": (1, "over-flow"),
    "3": (1, "under-flow"),
    "4": (2, "error"),
}

_HUMIDITY_DEFAULTS = {
    "levels": (30.0, 35.0),
    "levels_lower": (12.0, 8.0),
}


def _is_th2e(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host,
         _SYS_DESCRIBRIB],
        mutates=False,
    )
    if res.rc != 0:
        return False
    if "th2e" not in res.stdout.lower():
        return False
    res2 = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host, _SYS_OID],
        mutates=False,
    )
    if res2.rc != 0:
        return False
    return res2.stdout.strip().startswith("0.10.43.6.1.4.1")


def _walk_table(ctx, params, column_oid):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0 and res.rc != 127:
        return {}
    rows = {}
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        oid = sp[0]
        value = sp[1]
        idx = oid[len(column_oid) + 1:]
        if idx == "":
            continue
        rows[idx] = value
    return rows


def _get_scalar(ctx, params, oid):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip().strip('"')


def _read_sensors(ctx, params):
    end_values = _walk_table(ctx, params, _SNMP_BASE + ".1")
    state_values = _walk_table(ctx, params, _SNMP_BASE + ".2")
    reading_values = _walk_table(ctx, params, _SNMP_BASE + ".3")

    parsed = {}
    for idx in end_values:
        oidend = end_values[idx]
        state = state_values.get(idx, "1")
        reading_str = reading_values.get(idx, "0")
        if state == "3":
            continue
        if oidend not in _MAP_SENSOR_TYPE:
            continue
        sensor_ty = _MAP_SENSOR_TYPE[oidend]
        unit = _MAP_UNITS.get("0", "c")
        st = _MAP_STATES.get(state, (3, "not available"))
        reading_val = 0.0
        if reading_str.lstrip("-").isdigit():
            reading_val = float(reading_str) / 10.0
        parsed.setdefault(sensor_ty, {})
        item_key = "Sensor " + oidend
        parsed[sensor_ty][item_key] = (st, reading_val, unit, st[1])
    return parsed


def _discover(ctx, params):
    if not _is_th2e(ctx, params):
        return {"changed": False, "msg": "Papouch TH2E not found",
                "data": {"discovery": []}}
    sensors = _read_sensors(ctx, params)
    items = []
    for sensor_ty in sensors:
        for item_name in sensors[sensor_ty]:
            items.append({
                "item": item_name,
                "params": {},
                "metrics": ["temperature"],
            })
    return {"changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items}}


def _check_temp(ctx, params, item):
    sensors = _read_sensors(ctx, params)
    temp = sensors.get("temp", {})
    if item not in temp:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    (dev_state, reading, unit, state_readable) = temp[item]
    warn = params.get("warn", 70)
    crit = params.get("crit", 80)
    if dev_state == 0:
        levels = params.get("levels", (warn, crit))
        w = levels[0] if len(levels) >= 1 else warn
        c = levels[1] if len(levels) >= 2 else crit
    else:
        return {"changed": False,
                "msg": "Sensor %s: %s" % (item, state_readable),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": state_readable}}

    state = "OK"
    if reading >= c:
        state = "CRIT"
    elif reading >= w:
        state = "WARN"
    return {"changed": False,
            "msg": "Temperature %s: %f%s" % (item, reading, unit),
            "data": {"state": state,
                     "metrics": {"temperature": reading},
                     "details": "value: %f, unit: %s" % (reading, unit)}}


def _check(ctx, params):
    if not _is_th2e(ctx, params):
        return {"changed": False, "msg": "Papouch TH2E not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    item = params.get("item", "")
    return _check_temp(ctx, params, item)