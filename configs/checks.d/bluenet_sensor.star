# bluenet_sensor - Checkmk check translated to a read-only Starlark check module.
# Reproduces the Checkmk bluenet_sensor temperature AND humidity checks.
# The Checkmk SNMP section base is .1.3.6.1.4.1.21695.1.10.7.3.1 with OIDs
# 1 (sensor_id), 2 (sensor_type), 4 (temp), 5 (humidity).

# SNMP OID base and column suffixes (Checkmk SNMPTree.base + oids).
BLUENET_BASE = ".1.3.6.1.4.1.21695.1.10.7.3.1"
COL_SENSOR_ID = "1"
COL_SENSOR_TYPE = "2"
COL_TEMP = "4"
COL_HUM = "5"

# Sensor types: "1" = temperature only, "2" = combined temp/humidity.
SENSOR_TEMP = "1"
SENSOR_COMBINED = "2"

# Thresholds (Checkmk defaults).
TEMP_LEVELS = (28.0, 35.0)        # warn, crit (upper)
TEMP_LEVELS_LOWER = (13.0, 17.0)  # warn, crit (lower)
HUM_LEVELS = (60.0, 65.0)         # warn, crit (upper)
HUM_LEVELS_LOWER = (40.0, 35.0)   # warn, crit (lower)


def _sensor_descr(sensor_id):
    if sensor_id == "0":
        return "internal"
    return "external " + sensor_id


def _snmp_get(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _sys_descr(ctx, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovqn", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _walk_column(ctx, community, host, column_oid):
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
        # Format: "<full-oid>.<index> <value>" — split on FIRST whitespace.
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:].strip()
        idx = full_oid[len(column_oid) + 1:]
        rows.append((idx, value))
    return rows


def _fetch_sensors(ctx, community, host):
    # Walk the sensor_id column to enumerate sensor indices.
    id_rows = _walk_column(ctx, community, host, BLUENET_BASE + "." + COL_SENSOR_ID)
    sensors = []
    for idx, sensor_id in id_rows:
        sensor_type = _snmp_get(ctx, community, host, BLUENET_BASE + "." + COL_SENSOR_TYPE + "." + idx)
        temp_val = _snmp_get(ctx, community, host, BLUENET_BASE + "." + COL_TEMP + "." + idx)
        hum_val = _snmp_get(ctx, community, host, BLUENET_BASE + "." + COL_HUM + "." + idx)
        sensors.append({
            "index": idx,
            "sensor_id": sensor_id,
            "sensor_type": sensor_type,
            "temp": temp_val,
            "hum": hum_val,
        })
    return sensors


def _probe(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    sys_descr = _sys_descr(ctx, community, host)
    if not sys_descr or sys_descr.find("No Such") != -1 or sys_descr == "":
        return None
    sensors = _fetch_sensors(ctx, community, host)
    if not sensors:
        return []
    return sensors


def _grade_upper(value, levels):
    warn, crit = levels[0], levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _grade_lower(value, levels_lower):
    warn, crit = levels_lower[0], levels_lower[1]
    # Note: Checkmk lower levels use warn < crit ordering; warn triggers first
    # (value <= warn -> WARN), crit triggers at the lower threshold.
    if value <= crit:
        return "CRIT"
    if value <= warn:
        return "WARN"
    return "OK"


def _grade_temp(value, levels, levels_lower):
    up = _grade_upper(value, levels)
    low = _grade_lower(value, levels_lower)
    if up == "CRIT" or low == "CRIT":
        return "CRIT"
    if up == "WARN" or low == "WARN":
        return "WARN"
    return "OK"


def _grade_hum(value, levels, levels_lower):
    up = _grade_upper(value, levels)
    low = _grade_lower(value, levels_lower)
    if up == "CRIT" or low == "CRIT":
        return "CRIT"
    if up == "WARN" or low == "WARN":
        return "WARN"
    return "OK"


def main(ctx, params):
    # Discovery mode: enumerate temperature and humidity services.
    if params.get("_discover"):
        sensors = _probe(ctx, params)
        if sensors == None:
            return {"changed": False, "msg": "no SNMP connectivity", "data": {"discovery": [], "host_labels": {}}}
        out = []
        seen = set()
        for s in sensors:
            sensor_id = s.get("sensor_id")
            sensor_type = s.get("sensor_type")
            if sensor_id == None or sensor_type == None:
                continue
            if sensor_type in (SENSOR_TEMP, SENSOR_COMBINED):
                item = _sensor_descr(sensor_id)
                key = "temp:" + item
                if key not in seen:
                    seen.add(key)
                    out.append({
                        "item": item,
                        "params": {"warn": 28, "crit": 35, "warn_low": 13, "crit_low": 17},
                        "metrics": ["temperature"],
                        "service_labels": {"bluenet_sensor_id": sensor_id},
                    })
            if sensor_type == SENSOR_COMBINED:
                item = _sensor_descr(sensor_id)
                key = "hum:" + item
                if key not in seen:
                    seen.add(key)
                    out.append({
                        "item": item,
                        "params": {"warn": 60, "crit": 65, "warn_low": 40, "crit_low": 35},
                        "metrics": ["humidity"],
                        "service_labels": {"bluenet_sensor_id": sensor_id},
                    })
        host_labels = {}
        sys_descr = _sys_descr(ctx, params)
        if sys_descr:
            host_labels["cmk/sys_descr"] = sys_descr[:200]
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out, "host_labels": host_labels},
        }

    # Check mode: evaluate a single item.
    item = params.get("item", "")
    kind = params.get("_kind", "temperature")
    sensors = _probe(ctx, params)
    if sensors == None:
        return {
            "changed": False,
            "msg": "no SNMP connectivity to host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not sensors:
        return {
            "changed": False,
            "msg": "no temperature sensors found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    for s in sensors:
        sensor_id = s.get("sensor_id")
        sensor_type = s.get("sensor_type")
        if sensor_id == None:
            continue
        if _sensor_descr(sensor_id) != item:
            continue
        if kind == "temperature":
            if sensor_type not in (SENSOR_TEMP, SENSOR_COMBINED):
                return {
                    "changed": False,
                    "msg": "item is not a temperature sensor",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            temp_val = s.get("temp")
            if temp_val == None or temp_val == "":
                return {
                    "changed": False,
                    "msg": "no temperature reading for " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            temperature = float(temp_val) / 10.0
            warn = params.get("warn", 28)
            crit = params.get("crit", 35)
            warn_low = params.get("warn_low", 13)
            crit_low = params.get("crit_low", 17)
            state = _grade_temp(temperature, (warn, crit), (warn_low, crit_low))
            msg = "%s: %f C" % (item, temperature)
            details = "temperature: %f C (warn %f-%f, crit %f-%f)" % (
                temperature, warn_low, warn, crit_low, crit)
            return {
                "changed": False,
                "msg": msg,
                "data": {"state": state, "metrics": {"temperature": temperature}, "details": details},
            }
        elif kind == "humidity":
            if sensor_type != SENSOR_COMBINED:
                return {
                    "changed": False,
                    "msg": "item is not a humidity sensor",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            hum_val = s.get("hum")
            if hum_val == None or hum_val == "":
                return {
                    "changed": False,
                    "msg": "no humidity reading for " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
                }
            humidity = float(hum_val) / 10.0
            warn = params.get("warn", 60)
            crit = params.get("crit", 65)
            warn_low = params.get("warn_low", 40)
            crit_low = params.get("crit_low", 35)
            state = _grade_hum(humidity, (warn, crit), (warn_low, crit_low))
            msg = "%s: %f %%" % (item, humidity)
            details = "humidity: %f %% (warn %f-%f, crit %f-%f)" % (
                humidity, warn_low, warn, crit_low, crit)
            return {
                "changed": False,
                "msg": msg,
                "data": {"state": state, "metrics": {"humidity": humidity}, "details": details},
            }
        return {
            "changed": False,
            "msg": "unknown check kind: " + kind,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "item not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }