ALLNET_TABLE_OID = ".1.3.6.1.4.1.1839.2.1.1.1"
COL_NAME     = "2"
COL_VALUE    = "3"
COL_FUNCTION = "5"
COL_UNIT     = "6"


def _snmp_value(raw):
    if ": " in raw:
        return raw.split(": ", 1)[1].strip().strip('"')
    return raw.strip()


def _parse_sensors(stdout):
    sensors = {}
    for line in stdout.splitlines():
        line = line.strip()
        if " = " not in line:
            continue
        parts = line.split(" = ", 1)
        oid_parts = parts[0].strip().split(".")
        if len(oid_parts) < 2:
            continue
        idx = oid_parts[-1]
        col = oid_parts[-2]
        val = _snmp_value(parts[1])
        if idx not in sensors:
            sensors[idx] = {}
        sensors[idx][col] = val
    return sensors


def _is_pressure(sensor):
    return sensor.get(COL_FUNCTION, "") == "16" or sensor.get(COL_UNIT, "").lower() == "hpa"


def _make_item(idx, sensor):
    name = sensor.get(COL_NAME, "")
    if name:
        return name + " Sensor " + idx
    return "Sensor " + idx


def _to_float(s):
    s = s.strip()
    if s == "":
        return 0.0
    neg = s.startswith("-")
    body = s[1:] if neg else s
    if body == "":
        return 0.0
    dot_count = 0
    for c in body:
        if c == ".":
            dot_count += 1
            if dot_count > 1:
                return 0.0
        elif c < "0" or c > "9":
            return 0.0
    result = float(s)
    return result


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("snmp_version", "2c")

    res = ctx.run(
        ["snmpwalk", "-v" + version, "-c", community, "-On", host, ALLNET_TABLE_OID],
        mutates=False,
    )

    sensors = {}
    if res.rc == 0 and res.stdout.strip():
        sensors = _parse_sensors(res.stdout)

    if params.get("_discover"):
        items = []
        for idx in sorted(sensors.keys()):
            if _is_pressure(sensors[idx]):
                items.append({
                    "item": _make_item(idx, sensors[idx]),
                    "params": {},
                    "metrics": ["pressure"],
                })
        return {
            "changed": False,
            "msg": "discovered %d pressure sensors" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")

    if not sensors:
        return {
            "changed": False,
            "msg": "SNMP walk failed for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    matching = [
        sensors[idx]
        for idx in sensors
        if _is_pressure(sensors[idx]) and _make_item(idx, sensors[idx]) == item
    ]

    if len(matching) == 0:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensor = matching[0]
    pressure = _to_float(sensor.get(COL_VALUE, "0")) / 1000.0

    return {
        "changed": False,
        "msg": "%f bar" % pressure,
        "data": {
            "state": "OK",
            "metrics": {"pressure": pressure},
            "details": "",
        },
    }