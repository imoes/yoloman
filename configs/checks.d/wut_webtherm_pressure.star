"""Checkmk check: wut_webtherm_pressure — WUT WebTherm air pressure sensors.

Reads air-pressure sensor readings from a Wiesemann & Kuhn (WUT) WebTherm
SNMP device and reports the pressure in hPa. Read-only: never mutates state.
"""

_TYPE_TABLE_IDX = [1, 2, 3, 6, 7, 8, 9, 16, 18, 36, 37, 38, 42]

_MAP_SENSOR_TYPE = {
    "1": "temp",
    "2": "humid",
    "3": "air_pressure",
}

_DETECT_BASE_OID = ".1.3.6.1.2.1.1.2.0"
_DETECT_PREFIX = ".1.3.6.1.4.1.5040.1.2."

_COLS = ["2.1.1", "3.1.1"]


def _is_digit_like(s):
    """True if s looks like a parseable float (digits, optional sign, dot, comma)."""
    if s == None or s == "":
        return False
    if s.startswith("-") or s.startswith("+"):
        s = s[1:]
    if s == "" or s == "." or s == ",":
        return False
    ok = True
    seen_dot = False
    for ch in s:
        if ch == "." or ch == ",":
            if seen_dot:
                ok = False
                break
            seen_dot = True
        elif ch < "0" or ch > "9":
            ok = False
            break
    return ok


def _to_float(s):
    """Parse a float from a possibly comma-decimal string, guarded."""
    if not _is_digit_like(s):
        return None
    cleaned = s.replace(",", ".")
    if cleaned == None or cleaned == "":
        return None
    # Starlark float() will accept standard decimal strings; we've validated shape.
    return float(cleaned)


def _snmp_get(ctx, oid, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk(ctx, oid, community, host):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        lines.append((line[:sp], line[sp + 1:]))
    return lines


def _sys_object_id(ctx, host, community):
    return _snmp_get(ctx, _DETECT_BASE_OID, community, host)


def _is_wut_device(ctx, host, community):
    oid = _sys_object_id(ctx, host, community)
    if oid == None:
        return False
    return oid.startswith(_DETECT_PREFIX)


def _strip_value(raw):
    """Strip a leading SNMP type tag and surrounding quotes from a value string."""
    if raw == None:
        return ""
    s = raw
    cp = s.find(": ")
    if cp != -1:
        s = s[cp + 2:]
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    return s


def _parse_section(ctx, host, community):
    """Reproduce parse_wut_webtherm: build {sensor_id: {"type", "reading"}}.

    Each type-table index `idx` defines a base OID ".1.3.6.1.4.1.5040.1.2.{idx}.1"
    and columns. The Checkmk SNMPTree fetches ["2.1.1", "3.1.1", "8.1.1"]; the
    parser pairs (sensor_id, reading_de, reading_en) via zip(). We walk column
    "3.1.1" to enumerate sensors, then read "2.1.1" for the id with the same
    index suffix.
    """
    parsed = {}
    for idx in _TYPE_TABLE_IDX:
        base = ".1.3.6.1.4.1.5040.1.2.%s.1" % idx
        column_oid = base + ".3.1.1"
        walk = _snmp_walk(ctx, column_oid, community, host)
        if not walk:
            continue
        for oid, value in walk:
            suffix = oid[len(column_oid) + 1:]
            if suffix == "":
                continue
            if suffix.startswith("."):
                idx_str = suffix[1:]
            else:
                idx_str = suffix
            if idx_str == "":
                continue
            sensor_id = _snmp_get(ctx, base + ".2.1.1." + idx_str, community, host)
            if sensor_id == None:
                continue
            sensor_id = _strip_value(sensor_id)
            if sensor_id == "":
                continue
            reading_str = _strip_value(value)
            if reading_str == "" or "---" in reading_str:
                continue
            reading = _to_float(reading_str)
            if reading == None:
                continue
            webtherm_type = idx
            if webtherm_type <= 9:
                stype = "temp"
            else:
                stype = _MAP_SENSOR_TYPE.get(sensor_id, "unknown")
            parsed[sensor_id] = {"type": stype, "reading": reading}
    return parsed


def _all_pressure_sensors(ctx, host, community):
    if not _is_wut_device(ctx, host, community):
        return {}
    section = _parse_section(ctx, host, community)
    out = {}
    for sensor_id, vals in section.items():
        if vals.get("type") == "air_pressure":
            out[sensor_id] = vals
    return out


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        sensors = _all_pressure_sensors(ctx, host, community)
        discovery = []
        for sensor_id in sorted(sensors.keys()):
            discovery.append({
                "item": sensor_id,
                "params": {},
                "metrics": ["pressure"],
            })
        return {
            "changed": False,
            "msg": "discovered %d pressure sensors" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    sensors = _all_pressure_sensors(ctx, host, community)
    if item not in sensors:
        return {
            "changed": False,
            "msg": "no such pressure sensor: %s" % item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "pressure sensor %s not found on %s" % (item, host),
            },
        }

    reading = sensors[item]["reading"]
    return {
        "changed": False,
        "msg": "%f hPa" % reading,
        "data": {
            "state": "OK",
            "metrics": {"pressure": reading},
            "details": "Pressure sensor %s: %f hPa" % (item, reading),
        },
    }