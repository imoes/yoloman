# wut_webtherm — Checkmk check translated to read-only Starlark check module
# Monitors temperature/humidity/pressure sensors on WUT WebTherm devices via SNMP.

_TYPE_TABLE_IDX = [1, 2, 3, 6, 7, 8, 9, 16, 18, 36, 37, 38, 42]

_OID_COLUMNS = {
    "sensor_id": "2.1.1",
    "temp_value": "3.1.1",
    "temp_value_pkt": "8.1.1",
}

def _get_oid_value(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpget binary not found on host")
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val == "" or val == "No more variables left in this walk":
        return None
    return val

def _walk_oid(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        fail("snmpwalk binary not found on host")
    if res.rc != 0:
        return {}
    rows = {}
    for line in res.stdout.splitlines():
        space_idx = line.find(" ")
        if space_idx <= 0:
            continue
        oid_val = line[:space_idx]
        value = line[space_idx + 1:]
        rows[oid_val] = value
    return rows

def _get_snmp_table(ctx, host, community, base, oids):
    table = {}
    for col_idx, oid_suffix in enumerate(oids):
        full_oid = base + "." + oid_suffix
        walked = _walk_oid(ctx, host, community, full_oid)
        for row_oid, value in walked.items():
            idx = row_oid[len(full_oid) + 1:]
            if idx not in table:
                table[idx] = {}
            table[idx][col_idx] = value
    return table

def _parse_value(val_str):
    if val_str == None or val_str == "":
        return None
    cleaned = val_str.replace(",", ".")
    if cleaned == "" or "---" in cleaned:
        return None
    return float(cleaned) if _is_float(cleaned) else None

def _is_float(s):
    if s == None or s == "":
        return False
    dot_seen = False
    chars = list(s)
    for i, c in enumerate(chars):
        if c == "-" and i == 0:
            continue
        if c == ".":
            if dot_seen:
                return False
            dot_seen = True
            continue
        if c < "0" or c > "9":
            return False
    return True

def _fetch_section(ctx, host, community):
    BASE = ".1.3.6.1.4.1.5040.1.2"
    parsed = {}
    for idx in _TYPE_TABLE_IDX:
        base = BASE + "." + str(idx) + ".1"
        table = _get_snmp_table(ctx, host, community, base, [
            _OID_COLUMNS["sensor_id"],
            _OID_COLUMNS["temp_value"],
            _OID_COLUMNS["temp_value_pkt"],
        ])
        for sensor_idx, row in table.items():
            sensor_id = row.get(0, "")
            reading_de = row.get(2, "")
            reading_en = row.get(1, "")
            reading_str = reading_en if reading_en != "" else ""
            if reading_str == "":
                reading_str = reading_de.replace(",", ".") if reading_de != "" else ""
            reading = _parse_value(reading_str)
            if reading == None:
                continue
            if idx <= 9:
                parsed[sensor_id] = {"type": "temp", "reading": reading}
            else:
                type_map = {"1": "temp", "2": "humid", "3": "air_pressure"}
                sensor_type = type_map.get(sensor_id, "temp")
                parsed[sensor_id] = {"type": sensor_type, "reading": reading}
    return parsed

def _check_temperature(reading, params):
    levels = params.get("levels", (30.0, 35.0))
    if type(levels) == "list":
        if len(levels) >= 2:
            warn, crit = levels[0], levels[1]
        else:
            warn, crit = 30.0, 35.0
    else:
        warn, crit = levels[0], levels[1] if len(levels) > 1 else 35.0
    if reading >= crit:
        return "CRIT", warn, crit
    if reading >= warn:
        return "WARN", warn, crit
    return "OK", warn, crit

def _check_humidity(reading, params):
    levels = params.get("levels", (60.0, 65.0))
    levels_lower = params.get("levels_lower", (40.0, 35.0))
    if type(levels) == "list":
        warn_high, crit_high = levels[0], levels[1]
    else:
        warn_high, crit_high = levels[0], levels[1]
    if type(levels_lower) == "list":
        warn_low, crit_low = levels_lower[0], levels_lower[1]
    else:
        warn_low, crit_low = levels_lower[0], levels_lower[1]
    state = "OK"
    if reading >= crit_high or reading <= crit_low:
        state = "CRIT"
    elif reading >= warn_high or reading <= warn_low:
        state = "WARN"
    return state, warn_low, warn_high, crit_low, crit_high

def _is_number(v):
    return type(v) == "int" or type(v) == "float"

def _get_levels_tuple(levels, default_warn, default_crit):
    if type(levels) == "list" and len(levels) >= 2:
        return levels[0], levels[1]
    if type(levels) == "tuple" and len(levels) >= 2:
        return levels[0], levels[1]
    return default_warn, default_crit

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        probe = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if probe.rc == 127:
            return {"changed": False, "msg": "snmp not available",
                    "data": {"discovery": []}}
        if probe.rc != 0:
            return {"changed": False, "msg": "not a WUT WebTherm device",
                    "data": {"discovery": []}}
        sys_oid = probe.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.5040.1.2."):
            return {"changed": False, "msg": "not a WUT WebTherm device",
                    "data": {"discovery": []}}
        section = _fetch_section(ctx, host, community)
        discovery = []
        for sensor_id in section:
            if section[sensor_id]["type"] == "temp":
                discovery.append({
                    "item": sensor_id,
                    "params": {"levels": [30.0, 35.0]},
                    "metrics": ["temperature"],
                })
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    section = _fetch_section(ctx, host, community)

    if item not in section:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sensor = section[item]
    reading = sensor["reading"]
    sensor_type = sensor["type"]

    if sensor_type == "temp":
        levels = params.get("levels", [30.0, 35.0])
        warn, crit = _get_levels_tuple(levels, 30.0, 35.0)
        if reading >= crit:
            state = "CRIT"
        elif reading >= warn:
            state = "WARN"
        else:
            state = "OK"
        return {"changed": False,
                "msg": "Temperature: %f C (warn=%f, crit=%f)" % (reading, warn, crit),
                "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}
    elif sensor_type == "humid":
        levels = params.get("levels", [60.0, 65.0])
        levels_lower = params.get("levels_lower", [40.0, 35.0])
        warn_high, crit_high = _get_levels_tuple(levels, 60.0, 65.0)
        warn_low, crit_low = _get_levels_tuple(levels_lower, 40.0, 35.0)
        if reading >= crit_high or reading <= crit_low:
            state = "CRIT"
        elif reading >= warn_high or reading <= warn_low:
            state = "WARN"
        else:
            state = "OK"
        return {"changed": False,
                "msg": "Humidity: %f%% (warn=%f-%f, crit=%f-%f)" % (reading, warn_low, warn_high, crit_low, crit_high),
                "data": {"state": state, "metrics": {"humidity": reading}, "details": ""}}
    elif sensor_type == "air_pressure":
        return {"changed": False,
                "msg": "Pressure: %f hPa" % reading,
                "data": {"state": "OK", "metrics": {"pressure": reading}, "details": ""}}
    else:
        return {"changed": False, "msg": "unknown sensor type: " + sensor_type,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}