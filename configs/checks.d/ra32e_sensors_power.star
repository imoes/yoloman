def _get_oid_value(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return None
    return res.stdout.strip()


def _walk_table(ctx, community, host, column_oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        rows.append({"oid": oid, "value": value})
    return rows


def _safe_float(s):
    if s == None or s == "":
        return None
    s = s.strip()
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    if not s.replace(".", "", 1).isdigit():
        return None
    v = float(s)
    if neg:
        v = -v
    return v


def _safe_int(s):
    if s == None or s == "":
        return None
    s = s.strip()
    if not s.isdigit():
        return None
    return int(s)


def _parse_internal(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    t_v = _get_oid_value(ctx, community, host, ".1.3.6.1.4.1.20916.1.8.1.1.1.2")
    h_v = _get_oid_value(ctx, community, host, ".1.3.6.1.4.1.20916.1.8.1.1.2.1")
    hi_v = _get_oid_value(ctx, community, host, ".1.3.6.1.4.1.20916.1.8.1.1.4.2")

    temps = []
    for v in [t_v, h_v, hi_v]:
        fv = _safe_float(v)
        if fv == None:
            return None
        temps.append(fv)

    return {
        "temperature": temps[0] / 100.0,
        "humidity": temps[1] / 100.0,
        "heat_index": temps[2] / 100.0,
    }


def _parse_digital(ctx, params, i):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    col_base = ".1.3.6.1.4.1.20916.1.8.1.2.%d" % i
    rows = _walk_table(ctx, community, host, col_base)
    if not rows:
        return None

    values = {}
    for r in rows:
        suffix = r["oid"][len(col_base) + 1:]
        values[suffix] = r["value"]

    sensor_data = [
        values.get("1", ""),
        values.get("2", ""),
        values.get("3", ""),
        values.get("4", ""),
        values.get("5", ""),
    ]

    def has(n):
        return sensor_data[n] != None and sensor_data[n] != ""

    sec = None
    if has(0) and has(1) and not (has(2) or has(3) or has(4)):
        t = _safe_float(sensor_data[0])
        if t != None:
            sec = {"temperature": t / 100.0}
    elif has(0) and has(1) and has(2) and not (has(3) or has(4)):
        t = _safe_float(sensor_data[0])
        if t != None and sensor_data[2] in ("0", "1"):
            sec = {"temperature": t / 100.0, "power": sensor_data[2] == "1"}
    elif has(0) and has(1) and has(2) and has(3) and not has(4):
        t = _safe_float(sensor_data[0])
        v = _safe_int(sensor_data[2])
        if t != None and v != None:
            sec = {"temperature": t / 100.0, "voltage": v}
    elif has(0) and has(1) and has(2) and has(3) and has(4):
        t = _safe_float(sensor_data[0])
        h = _safe_float(sensor_data[2])
        hi = _safe_float(sensor_data[4])
        if t != None and h != None and hi != None:
            sec = {"temperature": t / 100.0, "humidity": h / 100.0, "heat_index": hi / 100.0}

    return sec


def _parse_section(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    sys_oid_value = _get_oid_value(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if sys_oid_value == None or "1.3.6.1.4.1.20916.1.8" not in sys_oid_value:
        return None

    internal = _parse_internal(ctx, params)
    digital = []
    for i in range(1, 9):
        digital.append(_parse_digital(ctx, params, i))

    if internal == None and not any(digital):
        return None
    return {"internal": internal, "digital": digital}


def _index_to_sensor(index):
    return "Sensor %d" % (index + 1)


def main(ctx, params):
    if params.get("_discover"):
        section = _parse_section(ctx, params)
        if section == None:
            return {"changed": False, "msg": "not a RoomAlert RA32E device", "data": {"discovery": [], "host_labels": {}}}

        discovery = []
        for i, ds in enumerate(section["digital"]):
            if ds == None or ds.get("power") == None:
                continue
            discovery.append({"item": _index_to_sensor(i), "params": {}, "metrics": ["power"]})

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {
                "discovery": discovery,
                "host_labels": {"cmk/os_family": "linux"},
            },
        }

    item = params.get("item", "")
    section = _parse_section(ctx, params)
    if section == None:
        return {"changed": False, "msg": "not a RoomAlert RA32E device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not item.startswith("Sensor "):
        return {"changed": False, "msg": "unknown item: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    idx = None
    tail = item[len("Sensor "):]
    if tail != None and tail != "" and tail.isdigit():
        idx = int(tail) - 1

    if idx == None or idx < 0 or idx >= len(section["digital"]):
        return {"changed": False, "msg": "sensor %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ds = section["digital"][idx]
    if ds == None or ds.get("power") == None:
        return {"changed": False, "msg": "no power data for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    power = ds["power"]
    if power:
        state = "OK"
        msg = "Power State %s: power detected" % item
    else:
        state = "CRIT"
        msg = "Power State %s: no power detected" % item

    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"power": 1 if power else 0}, "details": ""}}