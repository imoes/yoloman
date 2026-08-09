# watchdog_sensors_dew — translated Checkmk check

# SNMP OIDs for the Watchdog sensors device
_OID_SYS_DESC = ".1.3.6.1.2.1.1.2.0"
_OID_GENERAL = ".1.3.6.1.4.1.21239.5.1"
_OID_GENERAL_VERSION = ".1.3.6.1.4.1.21239.5.1.1.2"
_OID_GENERAL_TEMP_UNIT = ".1.3.6.1.4.1.21239.5.1.1.7"
_OID_TABLE_BASE = ".1.3.6.1.4.1.21239.5.1.2.1"

# Temperature check default parameters (Checkmk temperature ruleset)
_TEMP_DEFAULT_WARN = 60
_TEMP_DEFAULT_CRIT = 80


def _get_version(ctx, params):
    "Probe the device version via SNMP. Returns (version_str, temp_unit) or None"
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the device first — check sysObjectID
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_SYS_DESC],
        mutates=False,
    )
    if res.rc != 0:
        return None

    sys_desc = res.stdout.strip()
    if not (sys_desc.startswith(".1.3.6.1.4.1.21239.5.1") or
            sys_desc.startswith(".1.3.6.1.4.1.21239.42.1")):
        return None

    # Get version
    res_v = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_GENERAL_VERSION],
        mutates=False,
    )
    if res_v.rc != 0:
        return None

    version_str = res_v.stdout.strip()

    # Get temp unit
    res_u = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_GENERAL_TEMP_UNIT],
        mutates=False,
    )
    if res_u.rc != 0:
        return None

    unit_raw = res_u.stdout.strip()
    return (version_str, unit_raw)


def _get_sensor_rows(ctx, params):
    "Walk the sensor table and return list of (index, row_values)"
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Walk the sensor table using -Oqn for clean OID.value output
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, _OID_TABLE_BASE + ".1"],
        mutates=False,
    )
    if res.rc != 0:
        return None

    rows = {}
    col_oids = {}

    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1].strip().strip('"')

        # Extract index: oid is base.col.index, we want index
        suffix = oid[len(_OID_TABLE_BASE) + 1:]
        oid_parts = suffix.split(".")
        if len(oid_parts) < 2:
            continue
        col = oid_parts[0]
        idx = ".".join(oid_parts[1:])

        if idx not in rows:
            rows[idx] = {}
        rows[idx][col] = val

    return rows


def _parse_sensors(ctx, params):
    "Parse all sensor data from the device. Returns dict of dew sensors or None"
    version_info = _get_version(ctx, params)
    if version_info == None:
        return None

    version_str, unit_raw = version_info

    # Determine temp unit
    temp_unit = "C"
    if unit_raw == "1":
        temp_unit = "C"
    elif unit_raw == "0":
        temp_unit = "F"

    # Parse version number
    version_int = int(version_str.replace(".", "")) if version_str.replace(".", "").isdigit() else 0

    rows = _get_sensor_rows(ctx, params)
    if rows == None:
        return None

    # Column mapping: 1=sensor_id, 2=mac, 3=descr, 4=availability, 5=unknown, 6=temp, 7=humidity, 8=dew
    # For version <= 3.0.0 (300): columns shift
    dew_sensors = {}
    for idx in rows:
        row = rows[idx]
        if version_int <= 300:
            # Legacy: col 3=descr, col 4=availability, col 7=temp, col 6=humidity, col 8=dew
            descr = row.get("3", "")
            avail = row.get("4", "1")
            dew_val = row.get("8", "")
        else:
            # Version 3.2.0+: col 3=descr, col 4=availability, col 5=temp, col 6=unknown, col 7=humidity...
            # But from example: .1.3.6.1.4.1.21239.5.1.2.1.3.1 = descr (RSGLDN Watchdog 15)
            # .1.3.6.1.4.1.21239.5.1.2.1.4.1 = 1 (availability)
            # .1.3.6.1.4.1.21239.5.1.2.1.5.1 = 173 (temp)
            # .1.3.6.1.4.1.21239.5.1.2.1.6.1 = 46 (humidity)
            # .1.3.6.1.4.1.21239.5.1.2.1.7.1 = 56 (dew)
            # So columns: 3=descr, 4=availability, 5=temp, 6=humidity, 7=dew
            descr = row.get("3", "")
            avail = row.get("4", "1")
            dew_val = row.get("7", "")

        if dew_val == "":
            continue

        # Find sensor_id (col 1)
        sensor_id = row.get("1", idx)
        item_name = "Dew point %s" % sensor_id
        dew_sensors[item_name] = (dew_val, temp_unit)

    return dew_sensors


def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        sensors = _parse_sensors(ctx, params)
        if sensors == None or len(sensors) == 0:
            return {"changed": False, "msg": "no watchdog sensors found",
                    "data": {"discovery": []}}

        discovery = []
        for item_name in sorted(sensors.keys()):
            discovery.append({
                "item": item_name,
                "params": {},
                "metrics": ["temperature"],
            })

        return {"changed": False,
                "msg": "discovered %d dew point sensors" % len(discovery),
                "data": {"discovery": discovery}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    sensors = _parse_sensors(ctx, params)

    if sensors == None:
        return {"changed": False, "msg": "watchdog device not reachable via SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if len(sensors) == 0 or item not in sensors:
        return {"changed": False, "msg": "no dew point sensor '%s' found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    dew_raw, unit = sensors[item]

    # Convert dew value: raw is in tenths of a degree
    dew = float(dew_raw) / 10.0
    if unit == "F":
        dew = 5.0 / 9.0 * (dew - 32)

    warn = params.get("warn", _TEMP_DEFAULT_WARN)
    crit = params.get("crit", _TEMP_DEFAULT_CRIT)
    # Support levels tuple format
    levels = params.get("levels")
    if levels != None:
        warn = levels[0]
        crit = levels[1]

    # Temperature: warn/crit are upper thresholds
    if dew >= crit:
        state = "CRIT"
    elif dew >= warn:
        state = "WARN"
    else:
        state = "OK"

    details = "%s: %f %s" % (item, dew, unit.lower())

    return {"changed": False,
            "msg": "%s: %f %s" % (item, dew, unit.lower()),
            "data": {"state": state, "metrics": {"temperature": dew},
                     "details": details}}