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

_OID_BASE = ".1.3.6.1.4.1.18248.20.1.2.1.1"
_SYSCONTACT_OID = ".1.3.6.1.2.1.1.1.0"
_SYSSID_OID = ".1.3.6.1.2.1.1.2.0"


def _is_papouch(ctx):
    community = ctx.params.get("community", "public")
    host = ctx.params.get("host", "localhost")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _SYSCONTACT_OID],
        mutates=False,
    )
    if res.rc != 0:
        return False
    res2 = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _SYSSID_OID],
        mutates=False,
    )
    if res2.rc != 0:
        return False
    return "th2e" in res.stdout and res2.stdout.startswith(".0.10.43.6.1.4.1")


def _fetch_sensors(ctx):
    community = ctx.params.get("community", "public")
    host = ctx.params.get("host", "localhost")
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, _OID_BASE],
        mutates=False,
    )
    if res.rc != 0:
        return None
    raw = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1]
        if not oid.startswith(_OID_BASE + "."):
            continue
        idx = oid[len(_OID_BASE) + 1:]
        raw[idx] = value
    type_map = {}
    sensor_values = {}
    for k in sorted(raw.keys(), key=lambda x: len(x.split("."))):
        v = raw[k]
        comps = k.split(".")
        if len(comps) == 1:
            type_map[comps[0]] = _MAP_SENSOR_TYPE.get(v, "")
        elif len(comps) >= 2:
            col = comps[0]
            idx = ".".join(comps[1:])
            if col in ("1", "2", "3"):
                sensor_values.setdefault(idx, {})
                sensor_values[idx][col] = v
    parsed = {}
    for idx, st in type_map.items():
        if st not in ("temp", "humidity", "dewpoint"):
            continue
        if idx not in sensor_values:
            continue
        cols = sensor_values[idx]
        state = cols.get("1", "3")
        reading_str = cols.get("2", "")
        unit = cols.get("3", "0")
        if state == "3":
            continue
        sensor_unit = _MAP_UNITS.get(unit, "")
        if not reading_str or not reading_str.lstrip("-").replace(".", "", 1).isdigit():
            continue
        reading = float(reading_str) / 10
        (st_num, st_readable) = _MAP_STATES.get(state, (0, "OK"))
        item_name = "Sensor " + idx
        parsed.setdefault(st, {})
        parsed[st][item_name] = ((st_num, st_readable), reading, sensor_unit)
    return parsed if parsed else None


def main(ctx, params):
    ctx.params = params
    if not _is_papouch(ctx):
        if params.get("_discover"):
            return {"changed": False, "msg": "Papouch TH2E not detected", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "Papouch TH2E not detected on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if params.get("_discover"):
        section = _fetch_sensors(ctx)
        if section == None or "dewpoint" not in section:
            return {"changed": False, "msg": "no dewpoint sensors found", "data": {"discovery": []}}
        out = []
        for item in section["dewpoint"]:
            out.append({"item": item, "params": {}, "metrics": ["temperature"]})
        return {
            "changed": False,
            "msg": "discovered %d dewpoint sensors" % len(out),
            "data": {"discovery": out},
        }
    item = params.get("item", "")
    section = _fetch_sensors(ctx)
    if section == None or "dewpoint" not in section or item not in section["dewpoint"]:
        return {
            "changed": False,
            "msg": "no such dewpoint sensor: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    ((dev_state, state_readable), reading, unit) = section["dewpoint"][item]
    warn = None
    crit = None
    levels = params.get("levels")
    if levels != None and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    check_state = "OK"
    if dev_state != 0:
        check_state = "CRIT" if dev_state == 2 else ("WARN" if dev_state == 1 else "UNKNOWN")
    elif warn != None and crit != None:
        check_state = "CRIT" if reading >= crit else ("WARN" if reading >= warn else "OK")
    elif warn != None:
        check_state = "WARN" if reading >= warn else "OK"
    msg = "Dew point %s: %f %s" % (item, reading, unit)
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": check_state,
            "metrics": {"temperature": reading},
            "details": msg + " (device: %s)" % state_readable,
        },
    }